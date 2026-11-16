#!/bin/sh
# fetch_aframe.sh - install A-Frame for the Travel virtual-world view.
#
# The world page loads /js/aframe/aframe.min.js and nothing else: like the globe
# and the street map there is deliberately no CDN fallback, because a manager
# page runs with the house's session and a third-party script origin is not
# admitted. A-Frame bundles its own three.js and is over a megabyte, so
# public/js/aframe/ is gitignored: an installed asset, not source. Pinned to the
# exact npm version the world's components were written against.
#
#   sh scripts/fetch_aframe.sh
#
# Only curl and tar are needed.
set -eu

VERSION=1.8.0
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST="$ROOT/public/js/aframe"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

URL="https://registry.npmjs.org/aframe/-/aframe-${VERSION}.tgz"
echo "fetching A-Frame ${VERSION} ..."
curl -fsSL "$URL" -o "$TMP/aframe.tgz"

mkdir -p "$TMP/unpack"
tar -xzf "$TMP/aframe.tgz" -C "$TMP/unpack"

# the npm tarball keeps the browser build under package/dist
SRC="$TMP/unpack/package/dist/aframe-v${VERSION}.min.js"
if [ ! -f "$SRC" ]; then
	echo "unexpected A-Frame tarball layout: no dist/aframe-v${VERSION}.min.js" >&2
	exit 1
fi
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$SRC" "$DEST/aframe.min.js"
if [ -f "$TMP/unpack/package/LICENSE" ]; then
	cp "$TMP/unpack/package/LICENSE" "$DEST/aframe-LICENSE.txt"
fi
printf '%s\n' "$VERSION" > "$DEST/VERSION"

echo "installed A-Frame ${VERSION} to $DEST"
printf '  %8d  %s\n' "$(wc -c < "$DEST/aframe.min.js")" "aframe.min.js"
