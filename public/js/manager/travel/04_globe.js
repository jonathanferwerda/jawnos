// ---- the globe: the same ground on the whole world ----
// CesiumJS is a few megabytes that most opens of Travel never need, so it is not
// vendored in git: scripts/fetch_cesium.sh installs it under public/js/cesium/
// (gitignored), and the globe loads it from there. There is deliberately no CDN
// fallback: a manager page runs with the house's own session, and allowing a
// third-party origin in script-src to draw a bonus globe is not a trade this
// house makes. Without the local build the layer says how to install it.
//
// The viewer asks for no Cesium ion asset. OpenStreetMap imagery and the default
// ellipsoid terrain keep it keyless, the same rule the 2D map's free providers
// follow, so no token is stored anywhere.

var travelGlobeState = null;
var travelGlobeLoading = false;
var travelGlobeCss = false;

function travelGlobeOpen(lat, lon) {
	// one layer at a time: opening this closes the 3D model if it is up
	if (typeof travelNear3dClose === 'function') { travelNear3dClose(); }
	if (typeof travelWorldClose === 'function') { travelWorldClose(); }
	if (travelGlobeState) { travelGlobeClose(); }
	$('#travel_globe').css('display', 'flex');
	travelGlobeStatus('');
	var a = parseFloat(lat), b = parseFloat(lon);
	$('#travel_globe_title').text(jawnosT('Globe')
		+ ((isFinite(a) && isFinite(b)) ? ' · ' + a.toFixed(5) + ', ' + b.toFixed(5) : ''));
	if (window.Cesium) { travelGlobeStart(lat, lon, 'ready'); return; }
	if (travelGlobeLoading) { return; }
	travelGlobeLoading = true;
	travelGlobeLoad(function(source) {
		travelGlobeLoading = false;
		// the person may have closed the layer while Cesium was in flight
		if (!$('#travel_globe').is(':visible')) { return; }
		if (source == 'failed') {
			travelGlobeStatus(jawnosT('CesiumJS is not installed on this machine — run scripts/fetch_cesium.sh, then open the globe again.'));
			return;
		}
		travelGlobeStart(lat, lon, source);
	});
}

function travelGlobeStatus(text) {
	var line = $('#travel_globe_status');
	if (text) { line.text(text).css('display', 'block'); }
	else { line.text('').hide(); }
}

// The local build only. CESIUM_BASE_URL is what tells the build where its
// workers and imagery live; it has to be set before Cesium.js runs.
function travelGlobeLoad(done) {
	window.CESIUM_BASE_URL = '/js/cesium/';
	var script = document.createElement('script');
	script.src = '/js/cesium/Cesium.js';
	script.onload = function() {
		// a 200 that is not Cesium (an HTML page, say) is still a miss
		if (!window.Cesium) { done('failed'); return; }
		if (!travelGlobeCss) {
			travelGlobeCss = true;
			var link = document.createElement('link');
			link.rel = 'stylesheet';
			link.href = '/js/cesium/Widgets/widgets.css';
			document.head.appendChild(link);
		}
		done('local');
	};
	script.onerror = function() {
		if (script.parentNode) { script.parentNode.removeChild(script); }
		done('failed');
	};
	document.head.appendChild(script);
}

function travelGlobeStart(lat, lon, source) {
	var stage = document.getElementById('travel_globe_stage');
	if (!stage) { return; }
	$(stage).empty();
	travelGlobeStatus('');
	if (!window.Cesium) { travelGlobeStatus(jawnosT('CesiumJS is not installed on this machine.')); return; }

	var centre = (typeof travelNear3dCentre === 'function')
		? travelNear3dCentre(lat, lon)
		: { lat: parseFloat(lat) || 0, lon: parseFloat(lon) || 0 };
	var viewer;
	try {
		viewer = new Cesium.Viewer(stage, {
			// OSM needs no key and no ion account; the default terrain is the
			// ellipsoid, so nothing else is fetched
			baseLayer: new Cesium.ImageryLayer(new Cesium.OpenStreetMapImageryProvider({ url: 'https://tile.openstreetmap.org/' })),
			baseLayerPicker: false,
			geocoder: false,
			homeButton: true,
			sceneModePicker: false,
			navigationHelpButton: false,
			animation: false,
			timeline: false,
			fullscreenButton: true,
			infoBox: false,
			selectionIndicator: false
		});
	} catch (e) {
		travelGlobeStatus(jawnosT('This browser cannot draw the globe here.'));
		return;
	}

	var maps = (typeof travelAllMaps !== 'undefined' && travelAllMaps && travelAllMaps.length)
		? travelAllMaps : ((typeof mapData !== 'undefined' && mapData && mapData.all_maps) || []);
	$.each(maps, function(i, m) {
		if (!m || !m.file) { return; }
		if (!window.jawnosMap || typeof window.jawnosMap.mapBounds !== 'function') { return; }
		var b = window.jawnosMap.mapBounds(m);
		if (!b) { return; }
		// a Cesium rectangle is north-up; the 2D engine's tilt is not carried here
		// because a rectangle has no rotation. The picture still lands on the
		// right ground; only a screenshot taken askew sits a little off.
		viewer.entities.add({
			name: m.name || '',
			rectangle: {
				coordinates: Cesium.Rectangle.fromDegrees(b.nw.lon, b.se.lat, b.se.lon, b.nw.lat),
				height: 0,
				material: new Cesium.ImageMaterialProperty({
					image: m.file,
					transparent: true,
					color: m.guessed ? Cesium.Color.WHITE.withAlpha(0.45) : Cesium.Color.WHITE
				})
			}
		});
	});

	var near = (typeof mapData !== 'undefined' && mapData && mapData.near) || [];
	$.each(near, function(i, p) {
		var plat = parseFloat(p && p.latitude), plon = parseFloat(p && p.longitude);
		if (!isFinite(plat) || !isFinite(plon)) { return; }
		var colour = (p.settings && p.settings.colour) || p.colour || '#2f6f9f';
		viewer.entities.add({
			position: Cesium.Cartesian3.fromDegrees(plon, plat, 0),
			point: {
				pixelSize: 8,
				color: Cesium.Color.fromCssColorString(colour),
				outlineColor: Cesium.Color.BLACK,
				outlineWidth: 1
			},
			label: {
				text: p.name || p.app || '',
				font: '12px sans-serif',
				fillColor: Cesium.Color.WHITE,
				outlineColor: Cesium.Color.BLACK,
				outlineWidth: 2,
				style: Cesium.LabelStyle.FILL_AND_OUTLINE,
				pixelOffset: new Cesium.Cartesian2(0, -16),
				// labels only where they can be read: a globe-wide view is a
				// world of dots, not a pile of names
				distanceDisplayCondition: new Cesium.DistanceDisplayCondition(0, 200000)
			}
		});
	});

	// the same red pin for the machine's own position
	var here = (typeof mapData !== 'undefined' && mapData) ? mapData.position : null;
	if (here) {
		var hlat = parseFloat(here.latitude), hlon = parseFloat(here.longitude);
		if (isFinite(hlat) && isFinite(hlon)) {
			viewer.entities.add({
				position: Cesium.Cartesian3.fromDegrees(hlon, hlat, 0),
				point: { pixelSize: 12, color: Cesium.Color.RED, outlineColor: Cesium.Color.WHITE, outlineWidth: 2 },
				label: {
					text: here.label || jawnosT('You are here'),
					font: '13px sans-serif',
					fillColor: Cesium.Color.WHITE,
					outlineColor: Cesium.Color.BLACK,
					outlineWidth: 2,
					style: Cesium.LabelStyle.FILL_AND_OUTLINE,
					pixelOffset: new Cesium.Cartesian2(0, -20)
				}
			});
		}
	}

	// A neighbourhood is the useful first look, but a sphere seen from straight
	// above is a map. The house's globe is the ellipsoid (World Terrain needs a
	// Cesium ion token), so the ground itself is smooth; the tilt is what makes
	// the view read as a sphere - the horizon and the atmosphere come into it.
	viewer.camera.flyTo({
		destination: Cesium.Cartesian3.fromDegrees(centre.lon, centre.lat, 2500),
		orientation: { heading: 0, pitch: Cesium.Math.toRadians(-30), roll: 0 },
		duration: 1.5
	});

	travelGlobeState = { viewer: viewer, stage: stage };
}

function travelGlobeClose() {
	var st = travelGlobeState;
	travelGlobeState = null;
	if (st && st.viewer) {
		// destroy() removes the viewer's own canvas and widgets, and stops its
		// render loop; the stage belongs to the template, so it stays
		try { st.viewer.destroy(); } catch (e) {}
	}
	$('#travel_globe_stage').empty();
	$('#travel_globe').hide();
	travelGlobeStatus('');
}

$(document).on('click', '#travel_globe_close', function() { travelGlobeClose(); });
$(document).on('keyup', function(e) {
	if (e.key == 'Escape' && $('#travel_globe').is(':visible')) { travelGlobeClose(); }
});
