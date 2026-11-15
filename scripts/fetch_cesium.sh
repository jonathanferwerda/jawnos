#!/bin/sh
# fetch_cesium.sh - install CesiumJS for the Travel globe's offline path.
#
# The globe loads /js/cesium/Cesium.js first and only falls back to the CDN when
# that file is missing, so an offline house runs this once. The build is several
# megabytes and public/js/cesium/ is gitignored: it is an installed asset, not
# source. Pinned to the version the viewer's API was written against.
#
#   sh scripts/fetch_cesium.sh
#
# Only curl and tar are needed.
set -eu

VERSION=1.120
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST="$ROOT/public/js/cesium"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

URL="https://registry.npmjs.org/cesium/-/cesium-${VERSION}.tgz"
echo "fetching CesiumJS ${VERSION} ..."
curl -fsSL "$URL" -o "$TMP/cesium.tgz"

mkdir -p "$TMP/unpack"
tar -xzf "$TMP/cesium.tgz" -C "$TMP/unpack"

# the npm tarball keeps the browser build under package/Build/Cesium
if [ ! -d "$TMP/unpack/package/Build/Cesium" ]; then
	echo "unexpected Cesium tarball layout: no package/Build/Cesium" >&2
	exit 1
fi
rm -rf "$DEST"
mkdir -p "$(dirname -- "$DEST")"
mv "$TMP/unpack/package/Build/Cesium" "$DEST"
echo "installed to $DEST"
