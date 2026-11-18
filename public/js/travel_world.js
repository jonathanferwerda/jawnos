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
	// the moment a print was opened: a tap on a print is a press on the print,
	// and must not also be read as a step forward
	var last_photo_click = 0;

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

	// ---- walking: the rig moves in the ground plane, and only there ----------
	// A-Frame's wasd-controls moves whichever entity carries it and takes its
	// direction from that entity's own rotation, so on the camera the library
	// decides what pitch means - and a look down there is a step into the ground
	// the moment that changes. The rig walks instead: forward, back and sideways
	// only, its height put back every frame, and a fence at the edge of the
	// ground the archive actually covers. The arrow keys are the same four steps
	// as W A S D, so either hand finds them and neither ever changes altitude.
	var WALK_KEYS = {
		KeyW: 'forward', ArrowUp: 'forward',
		KeyS: 'back', ArrowDown: 'back',
		KeyA: 'left', ArrowLeft: 'left',
		KeyD: 'right', ArrowRight: 'right'
	};
	window.AFRAME.registerComponent('worldwalk', {
		schema: {
			speed: { default: 7 },          // metres a second
			acceleration: { default: 45 },  // metres a second squared: full speed in about a sixth of a second
			run: { default: 2.2 },          // Shift multiplies the speed
			step: { default: 9 },           // metres a double-tap moves you
			dashSpeed: { default: 24 },     // and how fast it crosses them
			radius: { default: 0 }          // 0 leaves the fence open
		},
		init: function () {
			var self = this;
			this.keys = {};
			this.velocity = new THREE.Vector3();
			this.forward = new THREE.Vector3();
			this.right = new THREE.Vector3();
			this.up = new THREE.Vector3(0, 1, 0);
			this.want = new THREE.Vector3();
			this.dashDir = new THREE.Vector3(0, 0, -1);
			this.dashLeft = 0;
			this.lastTap = 0;
			this.touchStepAt = 0;
			// the height the rig was built at is the eye's height for good
			this.eye = this.el.object3D.position.y;
			this.onKeyDown = function (e) {
				var step = WALK_KEYS[e.code];
				if (!step) { return; }
				self.keys[step] = true;
				self.running = !!e.shiftKey;
				// an arrow key would otherwise scroll the frame
				e.preventDefault();
			};
			this.onKeyUp = function (e) {
				var step = WALK_KEYS[e.code];
				if (!step) { return; }
				self.keys[step] = false;
				self.running = !!e.shiftKey;
			};
			this.onBlur = function () { self.keys = {}; };
			// A phone has no keys, so a double-tap is a step: the same distance
			// every time, whatever the frame rate or the size of the finger. A
			// drag to look is not a tap, and a tap that opened a print is not one
			// either - the print is what the person asked for.
			this.onTouchStart = function (e) {
				if (!e.touches || e.touches.length !== 1) { self.tap = null; return; }
				var t = e.touches[0];
				self.tap = { x: t.clientX, y: t.clientY, at: Date.now() };
			};
			this.onTouchEnd = function (e) {
				var tap = self.tap;
				self.tap = null;
				if (!tap || !e.changedTouches || !e.changedTouches.length) { return; }
				var t = e.changedTouches[0];
				if (Math.abs(t.clientX - tap.x) + Math.abs(t.clientY - tap.y) > 12) { return; }
				if (Date.now() - tap.at > 500) { return; }
				self.tapStep();
			};
			this.tapStep = function () {
				var now = Date.now();
				if (now - last_photo_click < 700) { return; }
				if (now - self.lastTap < 320) {
					self.lastTap = 0;
					self.touchStepAt = now;
					self.dash();
					return;
				}
				self.lastTap = now;
			};
			// a mouse reaches the same step as a double-click
			this.onDoubleClick = function () {
				if (Date.now() - last_photo_click < 700) { return; }
				if (Date.now() - self.touchStepAt < 500) { return; }   // a phone's tap already stepped
				self.dash();
			};
			window.addEventListener('keydown', this.onKeyDown);
			window.addEventListener('keyup', this.onKeyUp);
			window.addEventListener('blur', this.onBlur);
			window.addEventListener('touchstart', this.onTouchStart, { passive: true });
			window.addEventListener('touchend', this.onTouchEnd, { passive: true });
			window.addEventListener('dblclick', this.onDoubleClick);
		},
		remove: function () {
			window.removeEventListener('keydown', this.onKeyDown);
			window.removeEventListener('keyup', this.onKeyUp);
			window.removeEventListener('blur', this.onBlur);
			window.removeEventListener('touchstart', this.onTouchStart);
			window.removeEventListener('touchend', this.onTouchEnd);
			window.removeEventListener('dblclick', this.onDoubleClick);
		},
		// one step forward: a fixed distance along the look, spent over a glide
		dash: function () {
			if (!(+this.data.step > 0)) { return; }
			var cam = this.el.sceneEl && this.el.sceneEl.camera;
			this.dashDir.set(0, 0, -1);
			if (cam && typeof cam.getWorldDirection === 'function') { cam.getWorldDirection(this.dashDir); }
			this.dashDir.y = 0;
			if (this.dashDir.lengthSq() < 1e-6) { this.dashDir.set(0, 0, -1); }
			this.dashDir.normalize();
			this.dashLeft = +this.data.step;
		},
		// velocity moves toward the wanted one by at most `room` this frame, so
		// the acceleration is the one the schema states, not the frame rate's
		speedTo: function (target, room) {
			var dx = target.x - this.velocity.x;
			var dz = target.z - this.velocity.z;
			var len = Math.sqrt(dx * dx + dz * dz);
			if (len <= room || len === 0) { this.velocity.set(target.x, 0, target.z); return; }
			this.velocity.set(this.velocity.x + (dx / len) * room, 0, this.velocity.z + (dz / len) * room);
		},
		tick: function (time, delta) {
			var dt = Math.min(delta, 100) / 1000;
			if (!(dt > 0)) { return; }
			var p = this.el.object3D.position;
			// where the eye looks, flattened: pitch is never walked along
			var cam = this.el.sceneEl && this.el.sceneEl.camera;
			this.forward.set(0, 0, -1);
			if (cam && typeof cam.getWorldDirection === 'function') { cam.getWorldDirection(this.forward); }
			this.forward.y = 0;
			if (this.forward.lengthSq() < 1e-6) { this.forward.set(0, 0, -1); }
			this.forward.normalize();
			this.right.copy(this.forward).cross(this.up);
			var k = this.keys;
			this.want.set(0, 0, 0);
			if (k.forward) { this.want.add(this.forward); }
			if (k.back) { this.want.sub(this.forward); }
			if (k.right) { this.want.add(this.right); }
			if (k.left) { this.want.sub(this.right); }
			if (this.want.lengthSq() > 0) {
				this.want.normalize().multiplyScalar(this.data.speed * (this.running ? this.data.run : 1));
			}
			// the acceleration is stated, so a key answers at once and stops as
			// sharply as it starts rather than easing in over half a second
			this.speedTo(this.want, this.data.acceleration * (this.want.lengthSq() ? 1 : 2) * dt);
			this.velocity.y = 0;
			p.x += this.velocity.x * dt;
			p.z += this.velocity.z * dt;
			if (this.dashLeft > 0) {
				var step = Math.min(this.dashLeft, this.data.dashSpeed * dt);
				p.x += this.dashDir.x * step;
				p.z += this.dashDir.z * step;
				this.dashLeft -= step;
			}
			// nothing here writes the height but this line, and it always writes
			// the eye back: a look down, a drag or a stray transform cannot leave
			// the walker under the ground
			p.y = this.eye;
			var radius = +this.data.radius || 0;
			if (radius > 0) {
				var away = Math.sqrt(p.x * p.x + p.z * p.z);
				if (away > radius) { p.x *= radius / away; p.z *= radius / away; }
			}
		}
	});

	// three's ImageLoader asks for crossOrigin "anonymous", and Qt WebEngine never
	// completes a CORS-mode image for this app: a CORS request carries no session
	// cookie, so the file route refuses it and the image never loads. Every map
	// plate and photo print came through blank. A plain <img> sends the cookie,
	// and a same-origin texture needs no CORS.
	//
	// The URL also gets a nonce. Qt WebEngine leaves a picture wedged when an
	// earlier consumer of the same URL let it go - the world opens straight off
	// the long press's menu, whose previews have already asked for these
	// pictures - and the wedged entry never fires load or error again: a fresh
	// query string always starts clean (168 ms for a 600 KB plate). Reading a
	// local file once more is cheap beside a blank world.
	// `smooth` is for a picture seen edge-on and far away - the ground - where a
	// linear-filtered texture without mipmaps shimmers as the walker moves.
	var image_seq = 0;
	function imageTexture(url, done, smooth) {
		var img = new Image();
		// a data URL is already fresh, and has no query string to add a nonce to
		var nonce = url.indexOf('data:') === 0 ? ''
			: (url.indexOf('?') >= 0 ? '&' : '?') + 'world=' + (++image_seq);
		img.onload = function () {
			var tex = new THREE.Texture(img);
			if (smooth) {
				tex.minFilter = THREE.LinearMipmapLinearFilter;
				tex.magFilter = THREE.LinearFilter;
				tex.anisotropy = 4;
			}
			else {
				tex.minFilter = THREE.LinearFilter;
				tex.generateMipmaps = false;
			}
			tex.needsUpdate = true;
			if (done) { done(tex); }
		};
		img.onerror = function () { if (done) { done(null); } };
		img.src = url + nonce;
	}

	// ---- a measured map plate: a plane textured by three -------------------
	window.AFRAME.registerComponent('worldmap', {
		schema: {
			url: { default: '' },
			w: { default: 10 },
			d: { default: 10 },
			opacity: { default: 1 },
			// the colour the plane wears until its picture arrives (and if it
			// never does): the ground passes the colour of the plane it lies on
			colour: { default: '#ffffff' },
			y: { default: 0.02 },
			smooth: { default: false }
		},
		init: function () { this.build(); },
		update: function () { this.build(); },
		build: function () {
			var d = this.data;
			if (!d.url) { return; }
			var geo = new THREE.PlaneGeometry(Math.max(1, d.w), Math.max(1, d.d));
			geo.rotateX(-Math.PI / 2);
			var material = new THREE.MeshBasicMaterial({
				color: d.colour, transparent: true, opacity: d.opacity,
				side: THREE.DoubleSide, depthWrite: d.opacity >= 1
			});
			var mesh = new THREE.Mesh(geo, material);
			mesh.position.y = d.y;
			this.el.setObject3D('mesh', mesh);
			// the picture arrives when it arrives; the plane is already placed
			imageTexture(d.url, function (tex) {
				if (!tex) { return; }
				material.map = tex;
				material.needsUpdate = true;
			}, d.smooth);
		}
	});

	// ---- a picture, standing where it was taken ----------------------------
	window.AFRAME.registerComponent('worldphoto', {
		schema: { url: { default: '' } },
		init: function () {
			var d = this.data;
			var material = new THREE.MeshBasicMaterial({ color: 0xffffff, side: THREE.DoubleSide, transparent: true });
			if (d.url) {
				imageTexture(d.url, function (tex) {
					if (!tex) { return; }
					material.map = tex;
					material.needsUpdate = true;
				});
			}
			var mesh = new THREE.Mesh(new THREE.PlaneGeometry(2.4, 1.7), material);
			this.el.setObject3D('mesh', mesh);
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
			// the archive's own map painted into one picture: the streets, the
			// water, the land use and the building footprints, so the ground
			// reads as the place and not as a colour with pieces on it
			if (data.ground && data.ground.url) {
				el('a-entity', {
					worldmap: {
						url: data.ground.url, w: data.ground.w, d: data.ground.d,
						opacity: 1, colour: '#e2e8d8', y: 0.008, smooth: true
					}
				});
			}
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

		// ---- land cover under the town -------------------------------------
		(data.land || []).forEach(function (l) {
			el('a-entity', { flatpoly: { points: l.p, colour: l.c, opacity: 0.9, y: 0.012 } });
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
					facecam: '', worldlabel: { text: p.name, colour: '#ffffff', size: 0.7 }
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
				last_photo_click = Date.now();
				try { window.parent.postMessage({ type: 'travel_world_photo', f: ph.f }, location.origin); } catch (e) {}
			});
			if (ph.label) {
				el('a-entity', {
					position: ph.x + ' 2.9 ' + ph.z,
					facecam: '',
					worldlabel: { text: ph.label, colour: '#ffffff', size: 0.55 }
				});
			}
		});

		// stand back and above the press, as the template does, so the nearest
		// print is not in your face and the town reads in depth
		var rig = document.getElementById('world_rig');
		if (rig) {
			rig.setAttribute('position', '0 3 26');
			// the walk stops at the edge of the ground the archive covers: past
			// it there is no map, so a step there would be a step into nothing
			if (data.radius > 0) { rig.setAttribute('worldwalk', 'radius', +data.radius); }
		}
	}

	// The opening look is a little down, and it has to be the camera's own pitch:
	// a pitched rig turns the yaw about a tilted axis, so the horizon leans
	// further the more the person looks around - a head tipped to one side.
	// look-controls keeps its pitch in an object of its own (there is no markup
	// for a starting angle), so the angle is set there and the camera stays
	// upright underneath. The scene is level if that object ever moves.
	function lookDown(degrees) {
		var cam = document.getElementById('world_cam');
		var look = cam && cam.components && cam.components['look-controls'];
		if (!look || !look.pitchObject || !look.pitchObject.rotation) { return; }
		look.pitchObject.rotation.x = degrees * Math.PI / 180;
	}

	function ready() {
		var loading = document.getElementById('world_loading');
		if (loading && built) { loading.style.display = 'none'; }
		lookDown(-18);
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
