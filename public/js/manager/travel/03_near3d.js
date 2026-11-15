// ---- the 3D model: the measured maps standing on the ground ----
// three.js is vendored at /js/three.min.js and injected the first time this view
// is opened, so an install that never asks for it never pays for the 600 KB.
// The scene is local metres around the pressed point: x is east, z is south and
// y is up, using the same equirectangular approximation as jawnosMarkerMetres
// (111194.9 m per degree, longitude narrowed by cos(lat)). At house scale the
// error is centimetres; the globe is the view for the whole world.
//
// A guessed gap is drawn too, at a third of the opacity and with a dashed edge,
// so imagination never passes for measured ground - the same rule the 2D engine
// follows. A map saved tilted is turned about its home plate, as the 2D engine
// turns it, because a scale bar (the length the georeference rests on) survives
// a rotation unchanged.

var travelNear3dState = null;
var travelNear3dLoading = false;

function travelNear3dOpen(lat, lon) {
	// one layer at a time: opening this closes the globe if it is up
	if (typeof travelGlobeClose === 'function') { travelGlobeClose(); }
	if (travelNear3dState) { travelNear3dClose(); }
	$('#travel_3d').css('display', 'flex');
	travelNear3dNote(jawnosT('Building the 3D model…'));
	if (window.THREE) { travelNear3dStart(lat, lon); return; }
	if (travelNear3dLoading) { return; }
	travelNear3dLoading = true;
	var script = document.createElement('script');
	script.src = '/js/three.min.js';
	script.onload = function() {
		travelNear3dLoading = false;
		// the person may have closed the layer while the library was fetched
		if ($('#travel_3d').is(':visible')) { travelNear3dStart(lat, lon); }
	};
	script.onerror = function() {
		travelNear3dLoading = false;
		travelNear3dNote(jawnosT('The 3D model could not load three.js (/js/three.min.js).'));
	};
	document.head.appendChild(script);
}

function travelNear3dNote(text) {
	var note = $('#travel_3d_note');
	if (text) { note.text(text).css('display', 'flex'); }
	else { note.text('').hide(); }
}

function travelNear3dCentre(lat, lon) {
	var a = parseFloat(lat), b = parseFloat(lon);
	if (isFinite(a) && isFinite(b)) { return { lat: a, lon: b }; }
	var data = (typeof mapData !== 'undefined' && mapData) ? mapData : {};
	var origin = data.origin;
	if (origin) {
		a = parseFloat(origin.latitude); b = parseFloat(origin.longitude);
		if (isFinite(a) && isFinite(b)) { return { lat: a, lon: b }; }
	}
	// no press and no origin: open on the first measured map's middle, if any
	var maps = (typeof travelAllMaps !== 'undefined' && travelAllMaps && travelAllMaps.length)
		? travelAllMaps : (data.all_maps || []);
	for (var i = 0; i < maps.length; i++) {
		var b2 = window.jawnosMap && window.jawnosMap.mapBounds ? window.jawnosMap.mapBounds(maps[i]) : null;
		if (b2) { return { lat: (b2.nw.lat + b2.se.lat) / 2, lon: (b2.nw.lon + b2.se.lon) / 2 }; }
	}
	return { lat: 0, lon: 0 };
}

function travelNear3dWebgl() {
	try {
		var probe = document.createElement('canvas');
		return !!(window.WebGLRenderingContext && (probe.getContext('webgl') || probe.getContext('experimental-webgl')));
	} catch (e) { return false; }
}

function travelNear3dStart(lat, lon) {
	var stage = document.getElementById('travel_3d_stage');
	if (!stage) { return; }
	if (!travelNear3dWebgl()) {
		travelNear3dNote(jawnosT('This browser cannot draw WebGL, so the 3D model is unavailable here.'));
		return;
	}
	var centre = travelNear3dCentre(lat, lon);
	// local metres; north is -z, east is +x, matching the terms the rest of the
	// map code uses
	var MPD = 111194.9;
	var cosLat = Math.cos(centre.lat * Math.PI / 180);
	function metres(latitude, longitude) {
		return {
			x: (longitude - centre.lon) * MPD * cosLat,
			z: -(latitude - centre.lat) * MPD
		};
	}

	// drop a previous renderer's canvas, but keep #travel_3d_note: it belongs
	// to the template and is reused on every open
	var old = stage.querySelector('canvas');
	if (old && old.parentNode) { old.parentNode.removeChild(old); }
	travelNear3dNote('');

	var renderer = new THREE.WebGLRenderer({ antialias: true });
	renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
	renderer.setSize(stage.clientWidth || 640, stage.clientHeight || 360);
	renderer.domElement.style.display = 'block';
	renderer.domElement.style.width = '100%';
	renderer.domElement.style.height = '100%';
	renderer.domElement.style.touchAction = 'none';
	stage.appendChild(renderer.domElement);

	var scene = new THREE.Scene();
	scene.background = new THREE.Color(0x0b0d10);
	var camera = new THREE.PerspectiveCamera(60, (stage.clientWidth || 640) / (stage.clientHeight || 360), 0.5, 200000);

	scene.add(new THREE.HemisphereLight(0xdfe6ef, 0x1a1d22, 0.9));
	var sun = new THREE.DirectionalLight(0xffffff, 0.7);
	sun.position.set(400, 900, 300);
	scene.add(sun);

	// a two-part ground grid: 100 m squares with a 1 km frame, so a house and a
	// county can both be read at their own zoom
	var fine = new THREE.GridHelper(2000, 20, 0x26303a, 0x1b222a);
	fine.position.y = 0;
	scene.add(fine);
	var coarse = new THREE.GridHelper(10000, 10, 0x33404d, 0x232c35);
	coarse.position.y = -0.05;
	scene.add(coarse);

	// shared geometry: a pin is a shaft and a head, a plate is a house, so a
	// hundred places cost two geometries rather than two hundred
	var pinShaft = new THREE.CylinderGeometry(0.35, 0.35, 7, 6);
	pinShaft.translate(0, 3.5, 0);
	var pinHead = new THREE.SphereGeometry(0.95, 8, 6);
	pinHead.translate(0, 7.7, 0);
	var houseBody = new THREE.BoxGeometry(7, 5, 6);
	houseBody.translate(0, 2.5, 0);
	var houseRoof = new THREE.ConeGeometry(5, 3.2, 4);
	houseRoof.rotateY(Math.PI / 4);
	houseRoof.translate(0, 6.6, 0);

	function pin(colour, scale) {
		var group = new THREE.Group();
		var material = new THREE.MeshLambertMaterial({ color: new THREE.Color(colour || '#2f6f9f') });
		group.add(new THREE.Mesh(pinShaft, material));
		group.add(new THREE.Mesh(pinHead, material));
		if (scale) { group.scale.set(scale, scale, scale); }
		return group;
	}

	function house() {
		var group = new THREE.Group();
		var material = new THREE.MeshLambertMaterial({ color: new THREE.Color('#6f4f9f') });
		group.add(new THREE.Mesh(houseBody, material));
		group.add(new THREE.Mesh(houseRoof, material));
		return group;
	}

	// a label is a canvas texture on a sprite, so it always faces the camera
	function label(text) {
		var canvas = document.createElement('canvas');
		var ctx = canvas.getContext('2d');
		ctx.font = '600 24px sans-serif';
		var width = Math.ceil(ctx.measureText(text).width) + 18;
		canvas.width = width;
		canvas.height = 38;
		ctx = canvas.getContext('2d');
		ctx.font = '600 24px sans-serif';
		ctx.fillStyle = 'rgba(0,0,0,.58)';
		ctx.fillRect(0, 0, width, 38);
		ctx.fillStyle = '#fff';
		ctx.textBaseline = 'middle';
		ctx.fillText(text, 9, 20);
		var texture = new THREE.CanvasTexture(canvas);
		texture.minFilter = THREE.LinearFilter;
		var sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: texture, transparent: true, depthTest: false }));
		// about 9 m tall at the opening distance: readable without swallowing the
		// places it names
		sprite.scale.set(width * 0.25, 38 * 0.25, 1);
		return sprite;
	}

	var loader = new THREE.TextureLoader();
	var maps = (typeof travelAllMaps !== 'undefined' && travelAllMaps && travelAllMaps.length)
		? travelAllMaps : ((typeof mapData !== 'undefined' && mapData && mapData.all_maps) || []);
	var span = 0;

	$.each(maps, function(i, m) {
		if (!m || !m.file) { return; }
		if (!window.jawnosMap || typeof window.jawnosMap.mapBounds !== 'function') { return; }
		var bounds = window.jawnosMap.mapBounds(m);
		if (!bounds) { return; }
		var widthM = (bounds.se.lon - bounds.nw.lon) * MPD * cosLat;
		var heightM = (bounds.nw.lat - bounds.se.lat) * MPD;
		if (!(widthM > 0) || !(heightM > 0)) { return; }
		span = Math.max(span, widthM, heightM);

		var mid = metres((bounds.nw.lat + bounds.se.lat) / 2, (bounds.nw.lon + bounds.se.lon) / 2);
		// the plate is the pixel the picture is pinned by; it is the pivot of a
		// tilt, exactly as ctx.rotate turns the image about it in the 2D engine
		var hp = m.home_plate || {};
		var hx = parseFloat(hp.x), hy = parseFloat(hp.y);
		var hw = parseFloat(hp.width), hh = parseFloat(hp.height);
		if (!isFinite(hx)) { hx = 0; }
		if (!isFinite(hy)) { hy = 0; }
		var plateLat = bounds.nw.lat + (bounds.se.lat - bounds.nw.lat) * (hh > 0 ? hy / hh : 0.5);
		var plateLon = bounds.nw.lon + (bounds.se.lon - bounds.nw.lon) * (hw > 0 ? hx / hw : 0.5);
		var plate = metres(plateLat, plateLon);

		var geometry = new THREE.PlaneGeometry(widthM, heightM);
		// lay the picture flat: image x stays east, image y (down) becomes +z
		// (south), so no mirroring is needed
		geometry.rotateX(-Math.PI / 2);
		var texture = loader.load(m.file);
		if (renderer.capabilities && renderer.capabilities.getMaxAnisotropy) {
			texture.anisotropy = renderer.capabilities.getMaxAnisotropy();
		}
		var guessed = !!m.guessed;
		var material = new THREE.MeshBasicMaterial({
			map: texture,
			transparent: true,
			opacity: guessed ? 0.32 : 1,
			depthWrite: !guessed,
			side: THREE.DoubleSide
		});
		var mesh = new THREE.Mesh(geometry, material);
		mesh.position.set(mid.x - plate.x, 0.04, mid.z - plate.z);

		var group = new THREE.Group();
		group.position.set(plate.x, 0, plate.z);
		// the 2D engine's positive angle turns the picture east-toward-south; a
		// three.js +Y rotation turns east toward north, hence the sign
		group.rotation.y = -(parseFloat(m.rotate) || 0) * Math.PI / 180;
		group.add(mesh);

		if (guessed) {
			var hwd = widthM / 2, hhd = heightM / 2;
			var ox = mid.x - plate.x, oz = mid.z - plate.z;
			var edge = new THREE.Line(
				new THREE.BufferGeometry().setFromPoints([
					new THREE.Vector3(ox - hwd, 0.07, oz - hhd),
					new THREE.Vector3(ox + hwd, 0.07, oz - hhd),
					new THREE.Vector3(ox + hwd, 0.07, oz + hhd),
					new THREE.Vector3(ox - hwd, 0.07, oz + hhd),
					new THREE.Vector3(ox - hwd, 0.07, oz - hhd)
				]),
				new THREE.LineDashedMaterial({ color: 0xa0503f, dashSize: 5, gapSize: 4 })
			);
			edge.computeLineDistances();
			group.add(edge);
		}
		scene.add(group);
	});

	// places: a pin in the app's colour, with a label for the nearest twenty
	var near = (typeof mapData !== 'undefined' && mapData && mapData.near) || [];
	var labelled = 0;
	$.each(near, function(i, p) {
		var plat = parseFloat(p && p.latitude), plon = parseFloat(p && p.longitude);
		if (!isFinite(plat) || !isFinite(plon)) { return; }
		var at = metres(plat, plon);
		var colour = (p.settings && p.settings.colour) || p.colour || '#2f6f9f';
		var group = pin(colour, 1);
		group.position.set(at.x, 0, at.z);
		scene.add(group);
		if (labelled < 20 && (p.name || p.app)) {
			var text = p.name || p.app;
			var tag = label(text);
			tag.position.set(at.x, 11, at.z);
			scene.add(tag);
			labelled++;
		}
	});

	// home plates: the little houses the 2D map draws, standing up here
	$.each((typeof travelPlateList !== 'undefined' && travelPlateList) || [], function(i, p) {
		var plat = parseFloat(p && p.latitude), plon = parseFloat(p && p.longitude);
		if (!isFinite(plat) || !isFinite(plon)) { return; }
		var at = metres(plat, plon);
		var group = house();
		group.position.set(at.x, 0, at.z);
		scene.add(group);
	});

	// the machine's own position is the one red pin, as on the 2D map
	var here = (typeof mapData !== 'undefined' && mapData) ? mapData.position : null;
	if (here) {
		var hlat = parseFloat(here.latitude), hlon = parseFloat(here.longitude);
		if (isFinite(hlat) && isFinite(hlon)) {
			var at = metres(hlat, hlon);
			var red = pin('#d32f2f', 1.4);
			red.position.set(at.x, 0, at.z);
			scene.add(red);
			var hereTag = label(here.label || jawnosT('You are here'));
			hereTag.position.set(at.x, 13, at.z);
			scene.add(hereTag);
		}
	}

	// a small orbit rig: drag to swing around the pressed point, wheel or pinch
	// to move closer. Rendering is on demand (no animation loop), because
	// nothing in this scene moves on its own.
	var target = new THREE.Vector3(0, 0, 0);
	var open = {
		az: 0.65,
		elev: 0.82,
		dist: Math.max(140, Math.min(6000, span > 0 ? span * 1.35 : 220))
	};
	var rig = { az: open.az, elev: open.elev, dist: open.dist };

	function clampElev(v) { return Math.max(0.1, Math.min(1.45, v)); }
	function clampDist(v) { return Math.max(12, Math.min(20000, v)); }
	function apply() {
		var ce = Math.cos(rig.elev), se = Math.sin(rig.elev);
		camera.position.set(
			target.x + rig.dist * ce * Math.sin(rig.az),
			target.y + rig.dist * se,
			target.z + rig.dist * ce * Math.cos(rig.az)
		);
		camera.lookAt(target);
		renderer.render(scene, camera);
	}

	var canvas = renderer.domElement;
	var pointers = {};
	var drag = null;
	var pinch = null;
	function pinchDistance() {
		var ids = Object.keys(pointers);
		if (ids.length < 2) { return 0; }
		var a = pointers[ids[0]], b = pointers[ids[1]];
		return Math.sqrt(Math.pow(a.x - b.x, 2) + Math.pow(a.y - b.y, 2));
	}
	function onPointerDown(e) {
		try { canvas.setPointerCapture(e.pointerId); } catch (err) {}
		pointers[e.pointerId] = { x: e.clientX, y: e.clientY };
		if (Object.keys(pointers).length == 1) { drag = { x: e.clientX, y: e.clientY }; pinch = null; }
		else { drag = null; pinch = pinchDistance(); }
	}
	function onPointerMove(e) {
		if (!pointers[e.pointerId]) { return; }
		pointers[e.pointerId] = { x: e.clientX, y: e.clientY };
		if (Object.keys(pointers).length >= 2) {
			var d = pinchDistance();
			if (pinch > 0 && d > 0) { rig.dist = clampDist(rig.dist * (pinch / d)); }
			pinch = d;
			apply();
			return;
		}
		if (!drag) { return; }
		rig.az -= (e.clientX - drag.x) * 0.006;
		rig.elev = clampElev(rig.elev + (e.clientY - drag.y) * 0.006);
		drag = { x: e.clientX, y: e.clientY };
		apply();
	}
	function onPointerUp(e) {
		delete pointers[e.pointerId];
		drag = null;
		pinch = null;
	}
	function onWheel(e) {
		e.preventDefault();
		rig.dist = clampDist(rig.dist * (1 + (e.deltaY || 0) * 0.001));
		apply();
	}
	function onResize() {
		var w = stage.clientWidth || 640, h = stage.clientHeight || 360;
		renderer.setSize(w, h);
		camera.aspect = w / h;
		camera.updateProjectionMatrix();
		apply();
	}

	canvas.addEventListener('pointerdown', onPointerDown);
	canvas.addEventListener('pointermove', onPointerMove);
	canvas.addEventListener('pointerup', onPointerUp);
	canvas.addEventListener('pointercancel', onPointerUp);
	canvas.addEventListener('wheel', onWheel, { passive: false });
	window.addEventListener('resize', onResize);

	travelNear3dState = {
		renderer: renderer,
		scene: scene,
		camera: camera,
		canvas: canvas,
		rig: rig,
		open: open,
		onResize: onResize,
		listeners: [
			['pointerdown', onPointerDown], ['pointermove', onPointerMove],
			['pointerup', onPointerUp], ['pointercancel', onPointerUp],
			['wheel', onWheel]
		]
	};
	apply();
}

function travelNear3dReset() {
	var st = travelNear3dState;
	if (!st) { return; }
	st.rig.az = st.open.az;
	st.rig.elev = st.open.elev;
	st.rig.dist = st.open.dist;
	var ce = Math.cos(st.rig.elev), se = Math.sin(st.rig.elev);
	st.camera.position.set(
		st.rig.dist * ce * Math.sin(st.rig.az),
		st.rig.dist * se,
		st.rig.dist * ce * Math.cos(st.rig.az)
	);
	st.camera.lookAt(new THREE.Vector3(0, 0, 0));
	st.renderer.render(st.scene, st.camera);
}

function travelNear3dClose() {
	var st = travelNear3dState;
	travelNear3dState = null;
	if (st) {
		window.removeEventListener('resize', st.onResize);
		$.each(st.listeners || [], function(i, pair) {
			if (st.canvas && st.canvas.removeEventListener) { st.canvas.removeEventListener(pair[0], pair[1]); }
		});
		// dispose everything the scene owns: geometry, materials and the canvas
		// textures the labels and map planes loaded. Reopening then starts clean
		// instead of leaving a GPU copy of every map behind.
		if (st.scene) {
			st.scene.traverse(function(obj) {
				if (obj.geometry && obj.geometry.dispose) { obj.geometry.dispose(); }
				if (obj.material) {
					var list = Object.prototype.toString.call(obj.material) === '[object Array]' ? obj.material : [obj.material];
					$.each(list, function(i, material) {
						if (!material) { return; }
						$.each(['map', 'alphaMap', 'emissiveMap'], function(j, key) {
							if (material[key] && material[key].dispose) { material[key].dispose(); }
						});
						if (material.dispose) { material.dispose(); }
					});
				}
			});
		}
		if (st.renderer) { st.renderer.dispose(); }
	}
	// only the canvas goes: the stage's note element is the template's, and the
	// next open needs it to say whether three.js or WebGL is missing
	if (st && st.canvas && st.canvas.parentNode) { st.canvas.parentNode.removeChild(st.canvas); }
	$('#travel_3d').hide();
}

$(document).on('click', '#travel_3d_close', function() { travelNear3dClose(); });
$(document).on('click', '#travel_3d_reset', function() { travelNear3dReset(); });
$(document).on('keyup', function(e) {
	if (e.key == 'Escape' && $('#travel_3d').is(':visible')) { travelNear3dClose(); }
});
