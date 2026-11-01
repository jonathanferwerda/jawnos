/* [[js-split]]
   mapengine.js is part 1. The rest live in mapengine/ in name order:
     01_engine.js  - the whole jawnosMap engine as one IIFE
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
// jawnosMap: a small, dependency-free canvas map.
//
// A viewport — a centre latitude/longitude and a fractional zoom — drawn bottom
// to top as:
//   * a tile layer from a named provider (any {z}/{x}/{y} service), and
//   * your own measured maps, each placed by the georeference it carries (a
//     home_plate pixel sitting at a latitude/longitude, plus a scale bar giving
//     the ground metres between two pixels). Pan to a new area and whichever of
//     them covers it scrolls into view — that is "load the other maps we have".
//   * markers: the continent points, and the machine's current position.
//
// Drag to pan; a wheel or a pinch zooms (a trackpad's two-finger scroll zooms too),
// and a double-tap zooms in. With no provider chosen it fetches nothing and the
// measured maps are all it needs, so it stays usable offline; the tile layer is the
// online bonus.
//
// Everything is plain JS and jQuery-free; the page's own jQuery is not required.

