#!/bin/sh
# fetch_basemap_libs.sh - install MapLibre GL JS and PMTiles for the Travel
# street-map view.
#
# The view loads /js/basemap/maplibre-gl.css, /js/basemap/pmtiles.js and a
# MapLibre build from public/js/basemap/ and nothing else: like the Cesium
# globe, there is no CDN fallback and the CSP admits no third-party origin. The
# two libraries are a megabyte of installed asset rather than source, so
# public/js/basemap/ is gitignored and this script stages it.
#
# Both builds are the npm dist UMD files, pinned to the versions 05_basemap.js
# was written against.
#
# The CSP build (maplibre-gl-csp.js + maplibre-gl-csp-worker.js) is fetched
# beside the plain one because the house's policy has no `worker-src blob:`:
# the plain build starts its worker from a blob: URL, which 'self' does not
# cover, while the CSP build's worker is the same-origin file below.
#
#   sh scripts/fetch_basemap_libs.sh           install what is missing
#   sh scripts/fetch_basemap_libs.sh --force   reinstall the pinned versions
#
# Only curl and tar are needed.
set -eu

MAPLIBRE_VERSION=4.7.1
PMTILES_VERSION=3.2.1
STAMP="$MAPLIBRE_VERSION $PMTILES_VERSION"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST="$ROOT/public/js/basemap"
FILES="maplibre-gl.js maplibre-gl.css maplibre-gl-csp.js maplibre-gl-csp-worker.js pmtiles.js"

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; fi

# Idempotent: a second run over an intact install touches nothing.
if [ "$FORCE" = 0 ] && [ -f "$DEST/VERSION" ] && [ "$(cat "$DEST/VERSION")" = "$STAMP" ]; then
	missing=0
	for f in $FILES; do
		if [ ! -f "$DEST/$f" ]; then missing=1; fi
	done
	if [ "$missing" = 0 ]; then
		echo "basemap libs $STAMP are already installed in $DEST"
		exit 0
	fi
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

echo "fetching MapLibre GL JS $MAPLIBRE_VERSION ..."
curl -fsSL "https://registry.npmjs.org/maplibre-gl/-/maplibre-gl-${MAPLIBRE_VERSION}.tgz" -o "$TMP/maplibre.tgz"
echo "fetching PMTiles $PMTILES_VERSION ..."
curl -fsSL "https://registry.npmjs.org/pmtiles/-/pmtiles-${PMTILES_VERSION}.tgz" -o "$TMP/pmtiles.tgz"

mkdir -p "$TMP/maplibre" "$TMP/pmtiles"
tar -xzf "$TMP/maplibre.tgz" -C "$TMP/maplibre"
tar -xzf "$TMP/pmtiles.tgz" -C "$TMP/pmtiles"

for f in maplibre-gl.js maplibre-gl.css maplibre-gl-csp.js maplibre-gl-csp-worker.js; do
	if [ ! -f "$TMP/maplibre/package/dist/$f" ]; then
		echo "unexpected MapLibre tarball layout: no dist/$f" >&2
		exit 1
	fi
done
if [ ! -f "$TMP/pmtiles/package/dist/pmtiles.js" ]; then
	echo "unexpected PMTiles tarball layout: no dist/pmtiles.js" >&2
	exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
for f in maplibre-gl.js maplibre-gl.css maplibre-gl-csp.js maplibre-gl-csp-worker.js; do
	cp "$TMP/maplibre/package/dist/$f" "$DEST/$f"
done
cp "$TMP/pmtiles/package/dist/pmtiles.js" "$DEST/pmtiles.js"
# the licence both builds ship under travels with them
cp "$TMP/maplibre/package/dist/LICENSE.txt" "$DEST/maplibre-LICENSE.txt"
printf '%s\n' "$STAMP" > "$DEST/VERSION"

echo "installed MapLibre GL JS $MAPLIBRE_VERSION and PMTiles $PMTILES_VERSION to $DEST"
for f in $FILES maplibre-LICENSE.txt VERSION; do
	printf '  %8d  %s\n' "$(wc -c < "$DEST/$f")" "$f"
done
