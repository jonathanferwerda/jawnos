#!/bin/sh
# Build a binary .deb from a clean copy of HEAD.
#
#   sh packaging/build_deb.sh
#
# It extracts `git archive HEAD`, copies packaging/debian into place as
# debian/, fetches the two CPAN dists Debian does not package (cpanminus is
# needed), and runs dpkg-buildpackage. Artifacts land in packaging/out/.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VER=$(cat "$ROOT/VERSION")
OUT="$ROOT/packaging/out"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git -C "$ROOT" archive --prefix="jawnos-$VER/" HEAD | tar -x -C "$TMP"
cp -a "$ROOT/packaging/debian" "$TMP/jawnos-$VER/debian"

# The changelog's top version follows VERSION, so a release cannot ship a
# package named after the previous build.
top="jawnos ($VER-1) unstable; urgency=medium"
sed -i "1s/.*/$top/" "$TMP/jawnos-$VER/debian/changelog"

if [ ! -d "$ROOT/vendor/lib/perl5" ]; then
	sh "$ROOT/packaging/vendor/fetch.sh" deb
fi
cp -a "$ROOT/vendor" "$TMP/jawnos-$VER/vendor"

mkdir -p "$OUT"
cd "$TMP/jawnos-$VER"
dpkg-buildpackage -us -uc -b

find "$TMP" -maxdepth 1 -type f \
	\( -name '*.deb' -o -name '*.changes' -o -name '*.buildinfo' \) \
	-exec cp {} "$OUT/" \;

echo "artifacts in $OUT"
