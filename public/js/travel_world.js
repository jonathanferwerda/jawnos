// ---- the virtual world's renderer: A-Frame inside its own frame ----
// The Travel window opens /manager/travel/world in an iframe and posts a scene
// descriptor: measured map plates, extruded buildings, water, streams, roads,
// trees, places, plates and the pictures taken here. This file turns that into
// A-Frame entities. It is deliberately separate from the app's own scripts: the
// iframe exists so A-Frame's three.js and CSS cannot touch the panel.
//
// Coordinates are local metres around the press: x east, z south, y up. A photo
// keeps the direction its camera faced (heading, degrees clockwise from north)
// and hangs as a card whose front faces that way; a picture whose reading was
// relative, or absent, faces the pressed point instead.

(function () {
	if (typeof window.AFRAME === 'undefined') {
		try { window.parent.postMessage({ type: 'travel_world_missing' }, location.origin); } catch (e) {}
		return;
	}
	var THREE = window.AFRAME.THREE;
	var built = false;

	// ---- extruded building footprints ------------------------------------
	window.AFRAME.registerComponent('footprint', {
		schema: {
			points: { default: [] },
			height: { default: 6 },
			colour: { default: '#ded6c8' }
		},
		init: function () { this.build(); },
		update: function () { this.build(); },
		build: function () {
			var d = this.data;
			if (!d.points || d.points.length < 3) { return; }
			var shape = new THREE.Shape();
			for (var i = 0; i < d.points.length; i++) {
				var x = +d.points[i][0], z = +d.points[i][1];
				if (i === 0) { shape.moveTo(x, -z); }
				else { shape.lineTo(x, -z); }
			}
			shape.closePath();
			var height = Math.max(1, +d.height || 6);
			var geo = new THREE.ExtrudeGeometry(shape, { depth: height, bevelEnabled: false });
			// the shape lies in XY with y = -z; lay it on the ground and let the
			// extrusion become height instead of depth
			geo.rotateX(-Math.PI / 2);
			var material = new THREE.MeshLambertMaterial({ color: d.colour });
			var mesh = new THREE.Mesh(geo, material);
			mesh.position.y = 0.05;
			this.el.setObject3D('mesh', mesh);
		}
	});

	// ---- flat shapes: water and land -------------------------------
	window.AFRAME.registerComponent('flatpoly', {
		schema: {
			points: { default: [] },
			colour: { default: '#aac9dd' },
			opacity: { default: 1 },
			y: { default: 0.03 }
		},
		init: function () { this.build(); },
		update: function () { this.build(); },
		build: function () {
			var d = this.data;
			if (!d.points || d.points.length < 3) { return; }
			var shape = new THREE.Shape();
			for (var i = 0; i < d.points.length; i++) {
				var x = +d.points[i][0], z = +d.points[i][1];
				if (i === 0) { shape.moveTo(x, -z); }
				else { shape.lineTo(x, -z); }
			}
			shape.closePath();
			var geo = new THREE.ShapeGeometry(shape);
			geo.rotateX(-Math.PI / 2);
			var material = new THREE.MeshBasicMaterial({
				color: d.colour, transparent: d.opacity < 1, opacity: d.opacity,
				side: THREE.DoubleSide, depthWrite: d.opacity >= 1
			});
			var mesh = new THREE.Mesh(geo, material);
			mesh.position.y = d.y;
			this.el.setObject3D('mesh', mesh);
		}
	});

	// ---- a label that always faces the camera ------------------------------
	window.AFRAME.registerComponent('worldlabel', {
		schema: {
			text: { default: '' },
			colour: { default: '#ffffff' },
			background: { default: 'rgba(0,0,0,.58)' },
			size: { default: 0.55 }
		},
		init: function () { this.build(); },
		update: function () { this.build(); },
		build: function () {
			var d = this.data;
			if (!d.text) { return; }
			var canvas = document.createElement('canvas');
			var ctx = canvas.getContext('2d');
			ctx.font = '600 48px sans-serif';
			var width = Math.ceil(ctx.measureText(d.text).width) + 28;
			canvas.width = width; canvas.height = 64;
			ctx = canvas.getContext('2d');
			ctx.font = '600 48px sans-serif';
			ctx.fillStyle = d.background;
			ctx.fillRect(0, 0, width, 64);
			ctx.fillStyle = d.colour;
			ctx.textBaseline = 'middle';
			ctx.fillText(d.text, 14, 34);
			var texture = new THREE.CanvasTexture(canvas);
			texture.minFilter = THREE.LinearFilter;
			var height = d.size, wid = height * width / 64;
			var mesh = new THREE.Mesh(
				new THREE.PlaneGeometry(wid, height),
				new THREE.MeshBasicMaterial({ map: texture, transparent: true, depthTest: false })
			);
			mesh.renderOrder = 10;
			this.el.setObject3D('mesh', mesh);
		}
	});

	// a tiny billboard: the label's plane copies the camera's orientation
	window.AFRAME.registerComponent('facecam', {
		tick: function () {
			var cam = this.el.sceneEl && this.el.sceneEl.camera;
			if (!cam) { return; }
			this.el.object3D.quaternion.copy(cam.quaternion);
		}
	});

	// ---- a measured map plate: a plane textured by three -------------------
	window.AFRAME.registerComponent('worldmap', {
		schema: {
			url: { default: '' },
			w: { default: 10 },
			d: { default: 10 },
			opacity: { default: 1 }
		},
		init: function () { this.build(); },
		update: function () { this.build(); },
		build: function () {
			var d = this.data;
			if (!d.url) { return; }
			var geo = new THREE.PlaneGeometry(Math.max(1, d.w), Math.max(1, d.d));
			geo.rotateX(-Math.PI / 2);
			var material = new THREE.MeshBasicMaterial({
				color: 0xffffff, transparent: true, opacity: d.opacity,
				side: THREE.DoubleSide, depthWrite: d.opacity >= 1
			});
			var texture = new THREE.TextureLoader().load(d.url);
			// a picture is not a power-of-two texture: no mipmaps, so no GL warning
			texture.minFilter = THREE.LinearFilter;
			texture.generateMipmaps = false;
			material.map = texture;
			material.needsUpdate = true;
			var mesh = new THREE.Mesh(geo, material);
			mesh.position.y = 0.02;
			this.el.setObject3D('mesh', mesh);
		}
	});

	// ---- a picture, standing where it was taken ----------------------------
	window.AFRAME.registerComponent('worldphoto', {
		schema: { url: { default: '' } },
		init: function () {
			var d = this.data;
			var material = new THREE.MeshBasicMaterial({ color: 0xffffff, side: THREE.DoubleSide, transparent: true });
			if (d.url) {
				var texture = new THREE.TextureLoader().load(d.url);
				texture.minFilter = THREE.LinearFilter;
				texture.generateMipmaps = false;
				material.map = texture;
				material.needsUpdate = true;
			}
			var mesh = new THREE.Mesh(new THREE.PlaneGeometry(2.4, 1.7), material);
			this.el.setObject3D('mesh', mesh);
			// a dark backing card, so a picture reads as a print on a stand
			var back = new THREE.Mesh(
				new THREE.PlaneGeometry(2.56, 1.86),
				new THREE.MeshBasicMaterial({ color: 0x1c1c1c, side: THREE.DoubleSide })
			);
			back.position.z = -0.03;
			mesh.add(back);
		}
	});

	function el(tag, attrs, parent) {
		var e = document.createElement(tag);
		if (attrs) {
			for (var k in attrs) {
				if (!Object.prototype.hasOwnProperty.call(attrs, k)) { continue; }
				e.setAttribute(k, attrs[k]);
			}
		}
		(parent || document.getElementById('world_root')).appendChild(e);
		return e;
	}

	function safe(fn) {
		try { fn(); }
		catch (e) {
			try { window.parent.postMessage({ type: 'travel_world_error', message: String(e) }, location.origin); } catch (e2) {}
		}
	}

	function shade(height) {
		// a taller building is a touch warmer, so a street of them reads in relief
		var t = Math.min(1, Math.max(0, (height - 3) / 40));
		var r = Math.round(226 - t * 24), g = Math.round(216 - t * 32), b = Math.round(198 - t * 40);
		return 'rgb(' + r + ',' + g + ',' + b + ')';
	}

	function build(data) {
		if (built || !data) { return; }
		built = true;
		var loading = document.getElementById('world_loading');
		if (loading) { loading.style.display = 'none'; }
		var root = document.getElementById('world_root');
		if (!root) { return; }
		root.innerHTML = '';

		safe(function () {
			// the ground the whole world stands on
			el('a-plane', {
				width: 700, height: 700, rotation: '-90 0 0', position: '0 0 0',
				material: 'color: #e2e8d8; shader: flat'
			});
		});

	// ---- the measured maps, laid flat at their true place ----------------
		(data.maps || []).forEach(function (m) {
			if (!m || !m.url) { return; }
			var group = el('a-entity', { position: m.px + ' 0 ' + m.pz, rotation: '0 ' + (m.rot || 0) + ' 0' });
			// a texture loaded by three, not A-Frame's material src: the map file ends
			// .enc, and A-Frame's texture component reads an unknown suffix as a video
			el('a-entity', {
				position: m.x + ' 0 ' + m.z,
				worldmap: { url: m.url, w: m.w, d: m.d, opacity: m.opacity || 1 }
			}, group);
		});

		// ---- water, then the streams --------------------------------------
		(data.water || []).forEach(function (pts) {
			el('a-entity', { flatpoly: { points: pts, colour: '#aac9dd', opacity: 0.92, y: 0.03 } });
		});
		(data.streams || []).forEach(function (s) {
			el('a-box', {
				width: s.len, height: 0.06, depth: s.w,
				position: s.x + ' 0.035 ' + s.z, rotation: '0 ' + s.rot + ' 0',
				material: 'color: #aac9dd; shader: flat'
			});
		});

		// ---- roads ---------------------------------------------------------
		(data.roads || []).forEach(function (r) {
			el('a-box', {
				width: r.len, height: 0.06, depth: r.w,
				position: r.x + ' 0.04 ' + r.z, rotation: '0 ' + r.rot + ' 0',
				material: 'color: ' + r.c + '; shader: flat'
			});
		});

		// ---- buildings -----------------------------------------------------
		(data.buildings || []).forEach(function (b) {
			el('a-entity', { footprint: { points: b.p, height: b.h, colour: shade(b.h) } });
		});

		// ---- trees ---------------------------------------------------------
		(data.trees || []).forEach(function (t) {
			var tree = el('a-entity', { position: t.x + ' 0 ' + t.z, scale: t.s + ' ' + t.s + ' ' + t.s });
			el('a-cylinder', { radius: 0.22, height: 3, position: '0 1.5 0', material: 'color: #6b4f36; shader: flat' }, tree);
			el('a-cone', { radius: 1.7, height: 4.2, position: '0 4.6 0', material: 'color: #4f7a3a; shader: flat' }, tree);
		});

		// ---- places: a pin in the app's colour, with its name --------------
		(data.places || []).forEach(function (p) {
			var colour = p.colour || '#2f6f9f';
			var pin = el('a-entity', { position: p.x + ' 0 ' + p.z });
			el('a-cylinder', { radius: 0.22, height: 4, position: '0 2 0', material: 'color: ' + colour + '; shader: flat' }, pin);
			el('a-sphere', { radius: 0.6, position: '0 4.5 0', material: 'color: ' + colour + '; shader: flat' }, pin);
			if (p.name) {
				el('a-entity', {
					position: p.x + ' 5.6 ' + p.z,
					facecam: '', worldlabel: { text: p.name, colour: '#ffffff', size: 0.5 }
				});
			}
		});

		// ---- home plates: little houses ------------------------------------
		(data.plates || []).forEach(function (p) {
			var house = el('a-entity', { position: p.x + ' 0 ' + p.z });
			el('a-box', {
				width: 6, height: 4, depth: 5, position: '0 2 0',
				material: 'color: #6f4f9f; shader: flat'
			}, house);
			el('a-cone', {
				radius: 4.6, height: 2.8, segments: 4, rotation: '0 45 0', position: '0 5.4 0',
				material: 'color: #5a3f82; shader: flat'
			}, house);
		});

		// ---- the pictures taken here ---------------------------------------
		(data.photos || []).forEach(function (ph) {
			if (!ph || !ph.url) { return; }
			// the card's front is its +z. A heading clockwise from north points
			// at (sin h, -cos h), so the front turns to pi - h. A relative or
			// missing reading faces the pressed point instead.
			var yaw;
			if (ph.heading !== null && ph.heading !== undefined && ph.absolute) {
				yaw = Math.PI - (ph.heading * Math.PI / 180);
			}
			else {
				yaw = Math.atan2(-ph.x, -ph.z);
			}
			var card = el('a-entity', {
				position: ph.x + ' 1.65 ' + ph.z,
				rotation: '0 ' + (yaw * 180 / Math.PI) + ' 0',
				class: 'clickable',
				worldphoto: { url: ph.url }
			});
			card.addEventListener('click', function () {
				try { window.parent.postMessage({ type: 'travel_world_photo', f: ph.f }, location.origin); } catch (e) {}
			});
			if (ph.label) {
				el('a-entity', {
					position: ph.x + ' 2.9 ' + ph.z,
					facecam: '',
					worldlabel: { text: ph.label, colour: '#ffffff', size: 0.4 }
				});
			}
		});

		// stand back so the town is visible at once, looking north at the press
		var rig = document.getElementById('world_rig');
		if (rig) { rig.setAttribute('position', '0 1.7 16'); }
	}

	function ready() {
		var loading = document.getElementById('world_loading');
		if (loading && built) { loading.style.display = 'none'; }
		try { window.parent.postMessage({ type: 'travel_world_ready' }, location.origin); } catch (e) {}
	}

	var scene = document.getElementById('world_scene');
	if (!scene) { return; }
	if (scene.hasLoaded) { ready(); }
	else { scene.addEventListener('loaded', ready); }

	window.addEventListener('message', function (e) {
		if (e.origin !== location.origin || !e.data) { return; }
		if (e.data.type === 'travel_world_build') { safe(build.bind(null, e.data.data)); }
	});
})();
