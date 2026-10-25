// Remote keyboard and mouse for the Assistant's remote_control panel.
//
// The panel names a peer, and this file borrows this machine's pointer and keys
// for it. The chosen edge says where that screen sits beside this view: taking
// control enters from the touching edge, and coming back to that same edge (or
// pressing Escape, or pressing Release) hands the pointer and keys home again.
//
// Events are batched and sent through this machine's manager, which relays the
// batch to the peer over the signed rail; the peer's own manager injects it
// with the same backends the T-Deck's teletype uses (remote_input.pl). Moves are
// absolute fractions of the peer's screen, so a dropped batch cannot leave the
// pointer drifting.
(function () {
	'use strict';

	var R = window.jawnosRemoteInput = {
		on: false,
		enabled: false,
		controlling: false,
		uuid: '',
		edge: 'right',
		pos: { x: 0.5, y: 0.5 },
		returnArmed: false,
		locked: false,
		wantedLock: false,
		edgeArmed: false,
		queue: [],
		flushTimer: null,
		inFlight: false,
		sending: false,
		cooldownUntil: 0,
		backend: '',
		screen: null,
		lastError: '',
		bound: false
	};

	function panel() { return $('#remote_input_controls'); }

	function selectedName() {
		var opt = $('#remote_control_machine_select').find('option:selected');
		return opt.length ? $.trim(opt.text()) : '';
	}

	function selectedUuid() {
		var select = $('#remote_control_machine_select');
		if (select.length) { return select.val() || ''; }
		var p = panel();
		return p.length ? (p.attr('remote_uuid') || '') : '';
	}

	function currentEdge() {
		var e = $('#remote_input_edge').val();
		if (e !== 'left' && e !== 'right' && e !== 'top' && e !== 'bottom') {
			var p = panel();
			e = (p.length && p.attr('data-edge')) || R.edge || 'right';
		}
		return e;
	}

	function edgeLabel(edge) {
		var opt = $('#remote_input_edge option[value="' + edge + '"]');
		return opt.length ? $.trim(opt.text()) : edge;
	}

	function paints() {
		var state = $('#remote_input_state');
		if (!state.length) { return; }
		var name = selectedName();
		if (!R.on) {
			state.text('');
		}
		else if (!R.uuid) {
			state.text(jawnosT('Pick a machine other than Me first.'));
		}
		else if (R.controlling) {
			var hint = R.locked
				? jawnosT('Escape or the {0} edge returns here.', edgeLabel(R.edge))
				: jawnosT('Press Release when you are done.');
			var line = jawnosT('Controlling {0}. {1}', name, hint);
			state.text(R.lastError ? (line + ' ' + R.lastError) : line);
		}
		else if (R.lastError) {
			state.text(R.lastError);
		}
		else if (R.edgeArmed) {
			state.text(jawnosT('Click to take control of {0}.', name));
		}
		else {
			state.text(jawnosT('Ready. Click Take control, or click at the {0} edge.', edgeLabel(R.edge)));
		}
		$('#remote_input_take').toggle(!R.controlling).prop('disabled', !R.on || !R.uuid);
		$('#remote_input_return').toggle(R.controlling);
		$('#remote_input_type_wrap').toggle(R.controlling);
		$('#remote_input_edge_row').css('opacity', R.on ? 1 : 0.55);
	}

	function clearQueue() {
		R.queue = [];
		if (R.flushTimer) { clearTimeout(R.flushTimer); R.flushTimer = null; }
	}

	function pushEvent(ev) {
		if (!R.on || !R.uuid) { return; }
		var q = R.queue;
		if (ev.t === 'move' && q.length && q[q.length - 1].t === 'move') {
			q[q.length - 1] = ev;
		}
		else {
			q.push(ev);
			if (q.length > 300) { q.splice(0, q.length - 300); }
		}
		scheduleFlush();
	}

	function scheduleFlush() {
		if (R.flushTimer) { return; }
		R.flushTimer = setTimeout(flush, 24);
	}

	function flush() {
		R.flushTimer = null;
		if (!R.uuid) { return; }
		if (!R.on) {
			// A release may still be waiting behind a batch that was in flight when
			// the panel was switched off; it is the one event that must go through.
			var ending = false;
			for (var n = 0; n < R.queue.length; n++) { if (R.queue[n].t === 'release') { ending = true; } }
			if (!ending) { R.queue = []; return; }
		}
		if (!R.queue.length) { return; }
		if (R.inFlight) { scheduleFlush(); return; }
		var batch = R.queue;
		R.queue = [];
		R.inFlight = true;
		$.ajax({
			url: '/manager/remote_input/send',
			type: 'POST',
			dataType: 'json',
			timeout: 12000,
			data: { remote_uuid: R.uuid, events: JSON.stringify(batch) },
			success: function (r) {
				if (!r || r.ok === 0 || r.ok === false) {
					R.lastError = (r && r.error) || jawnosT('That machine refused the input.');
					paints();
					return;
				}
				R.backend = r.backend || R.backend;
				R.screen = r.screen || R.screen;
				if (R.lastError) { R.lastError = ''; paints(); }
				if (R.backend === 'none') {
					R.lastError = jawnosT('That machine has no input backend installed.');
					paints();
				}
				else if (!R.screen) {
					R.lastError = jawnosT('That machine does not know its screen size.');
					paints();
				}
			},
			error: function () {
				R.lastError = jawnosT('That machine did not answer.');
				paints();
			},
			complete: function () {
				R.inFlight = false;
				if (R.queue.length) { scheduleFlush(); }
			}
		});
	}

	function sendNow(ev) {
		if (!R.uuid) { return; }
		clearQueue();
		if (R.inFlight) {
			// let the batch in flight finish, then release the keys/buttons on its
			// tail; keeps the release behind the events it is ending
			R.queue = [ev];
			scheduleFlush();
			return;
		}
		R.inFlight = true;
		$.ajax({
			url: '/manager/remote_input/send',
			type: 'POST',
			dataType: 'json',
			timeout: 8000,
			data: { remote_uuid: R.uuid, events: JSON.stringify([ev]) },
			complete: function () {
				R.inFlight = false;
				if (R.queue.length) { scheduleFlush(); }
			}
		});
	}

	function isControlTarget(e) {
		return !!(e.target && $(e.target).closest('#remote_input_controls').length);
	}

	function atEdge(x, y) {
		var pad = 3;
		if (R.edge === 'left') { return x <= pad; }
		if (R.edge === 'right') { return x >= window.innerWidth - pad - 1; }
		if (R.edge === 'top') { return y <= pad; }
		return y >= window.innerHeight - pad - 1;
	}

	function startPosition(edge) {
		if (edge === 'left') { return { x: 1, y: 0.5 }; }
		if (edge === 'right') { return { x: 0, y: 0.5 }; }
		if (edge === 'top') { return { x: 0.5, y: 1 }; }
		return { x: 0.5, y: 0 };
	}

	// The edge the pointer must come back to: the touching edge of the other
	// screen, which is the same side of this view that was named.
	function backToStart() {
		if (R.edge === 'left') { return R.pos.x >= 0.998; }
		if (R.edge === 'right') { return R.pos.x <= 0.002; }
		if (R.edge === 'top') { return R.pos.y >= 0.998; }
		return R.pos.y <= 0.002;
	}

	function awayFromStart() {
		if (R.edge === 'left') { return R.pos.x < 0.97; }
		if (R.edge === 'right') { return R.pos.x > 0.03; }
		if (R.edge === 'top') { return R.pos.y < 0.97; }
		return R.pos.y > 0.03;
	}

	function take() {
		if (!R.on || !R.uuid || R.controlling) { return; }
		R.controlling = true;
		R.lastError = '';
		R.edgeArmed = false;
		R.pos = startPosition(R.edge);
		R.returnArmed = false;
		R.wantedLock = true;
		try {
			var target = document.documentElement;
			if (target.requestPointerLock) {
				var p = target.requestPointerLock();
				if (p && p.catch) { p.catch(function () { R.wantedLock = false; paints(); }); }
			}
			else {
				R.wantedLock = false;
			}
		}
		catch (e) { R.wantedLock = false; }
		var type = $('#remote_input_type');
		if (type.length) { type.val(''); }
		try {
			if (document.activeElement && document.activeElement.blur) { document.activeElement.blur(); }
		}
		catch (e) {}
		pushEvent({ t: 'move', x: R.pos.x, y: R.pos.y });
		paints();
	}

	function release(reason) {
		if (!R.controlling) { return; }
		R.controlling = false;
		R.returnArmed = false;
		R.edgeArmed = false;
		R.cooldownUntil = Date.now() + 400;
		sendNow({ t: 'release' });
		try {
			if (document.pointerLockElement) { document.exitPointerLock(); }
		}
		catch (e) {}
		R.locked = false;
		R.wantedLock = false;
		paints();
	}

	function stop() {
		clearQueue();
		R.on = false;
		if (R.controlling) { release('stopped'); }
		R.uuid = '';
		R.locked = false;
		R.wantedLock = false;
		paints();
	}

	// ------------------------------------------------------------------ keys

	var KEY_NAMES = {
		Escape: 'Escape', Enter: 'Return', NumpadEnter: 'KP_Enter', Tab: 'Tab',
		Backspace: 'BackSpace', Delete: 'Delete', Insert: 'Insert',
		Home: 'Home', End: 'End', PageUp: 'Prior', PageDown: 'Next',
		ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right',
		Space: 'space', CapsLock: 'Caps_Lock', ContextMenu: 'Menu',
		PrintScreen: 'Print', ScrollLock: 'Scroll_Lock', Pause: 'Pause',
		NumLock: 'Num_Lock',
		Minus: 'minus', Equal: 'equal', BracketLeft: 'bracketleft',
		BracketRight: 'bracketright', Backslash: 'backslash',
		Semicolon: 'semicolon', Quote: 'apostrophe', Backquote: 'grave',
		Comma: 'comma', Period: 'period', Slash: 'slash',
		IntlBackslash: 'backslash', IntlRo: 'Romaji', IntlYen: 'yen',
		NumpadAdd: 'KP_Add', NumpadSubtract: 'KP_Subtract',
		NumpadMultiply: 'KP_Multiply', NumpadDivide: 'KP_Divide',
		NumpadDecimal: 'KP_Decimal'
	};

	function keyName(e) {
		if (KEY_NAMES[e.code]) { return KEY_NAMES[e.code]; }
		if (/^Key[A-Z]$/.test(e.code)) { return e.code.slice(3).toLowerCase(); }
		if (/^Digit[0-9]$/.test(e.code)) { return e.code.slice(5); }
		if (/^Numpad[0-9]$/.test(e.code)) { return 'KP_' + e.code.slice(6); }
		if (/^F(?:[1-9]|1[0-2])$/.test(e.code)) { return e.code; }
		if (e.key && e.key.length === 1 && /[A-Za-z0-9]/.test(e.key)) {
			return e.key.toLowerCase();
		}
		return '';
	}

	function keySpec(e) {
		var name = keyName(e);
		if (!name) { return ''; }
		var mods = [];
		if (e.ctrlKey) { mods.push('ctrl'); }
		if (e.altKey) { mods.push('alt'); }
		if (e.shiftKey) { mods.push('shift'); }
		if (e.metaKey) { mods.push('super'); }
		return mods.concat([name]).join('+');
	}

	function typeFromKey(e) {
		if (!e.key || e.key.length !== 1) { return ''; }
		if (e.ctrlKey || e.altKey || e.metaKey) { return ''; }
		return e.key;
	}

	function typed(text) {
		if (!text) { return; }
		pushEvent({ t: 'type', s: text });
	}

	// --------------------------------------------------------------- listeners

	function bind() {
		if (R.bound) { return; }
		R.bound = true;

		document.addEventListener('pointermove', function (e) {
			if (!R.on) { return; }
			if (!R.controlling) {
				var armed = !!(R.uuid && Date.now() > R.cooldownUntil
					&& atEdge(e.clientX, e.clientY));
				if (armed !== R.edgeArmed) {
					R.edgeArmed = armed;
					paints();
				}
				return;
			}
			var dx = (typeof e.movementX === 'number') ? e.movementX : 0;
			var dy = (typeof e.movementY === 'number') ? e.movementY : 0;
			if (!R.locked) {
				// Without a pointer lock the cursor stops at the screen edge, so
				// the position is read directly; movementX carries the push past
				// the edge where the browser reports it.
				if (dx || dy) {
					R.pos.x += dx / Math.max(1, window.innerWidth);
					R.pos.y += dy / Math.max(1, window.innerHeight);
				}
				else {
					R.pos.x = e.clientX / Math.max(1, window.innerWidth);
					R.pos.y = e.clientY / Math.max(1, window.innerHeight);
				}
			}
			else {
				R.pos.x += dx / Math.max(1, window.innerWidth);
				R.pos.y += dy / Math.max(1, window.innerHeight);
			}
			R.pos.x = Math.max(0, Math.min(1, R.pos.x));
			R.pos.y = Math.max(0, Math.min(1, R.pos.y));
			if (!R.returnArmed && awayFromStart()) { R.returnArmed = true; }
			pushEvent({ t: 'move', x: R.pos.x, y: R.pos.y });
			if (R.returnArmed && backToStart()) { release('edge'); }
		}, true);

		document.addEventListener('pointerdown', function (e) {
			if (!R.on) { return; }
			if (!R.controlling) {
				if (R.edgeArmed && Date.now() > R.cooldownUntil && atEdge(e.clientX, e.clientY) && !isControlTarget(e)) {
					e.preventDefault();
					e.stopPropagation();
					take();
				}
				return;
			}
			if (isControlTarget(e)) { return; }
			var b = e.button === 2 ? 'right' : (e.button === 1 ? 'middle' : 'left');
			e.preventDefault();
			e.stopPropagation();
			pushEvent({ t: 'button', b: b, d: 1 });
		}, true);

		document.addEventListener('pointerup', function (e) {
			if (!R.on || !R.controlling) { return; }
			if (isControlTarget(e)) { return; }
			var b = e.button === 2 ? 'right' : (e.button === 1 ? 'middle' : 'left');
			e.preventDefault();
			e.stopPropagation();
			pushEvent({ t: 'button', b: b, d: 0 });
		}, true);

		document.addEventListener('contextmenu', function (e) {
			if (!R.on || !R.controlling) { return; }
			e.preventDefault();
			e.stopPropagation();
		}, true);

		document.addEventListener('wheel', function (e) {
			if (!R.on || !R.controlling) { return; }
			if (isControlTarget(e)) { return; }
			e.preventDefault();
			e.stopPropagation();
			var dy = e.deltaY ? (e.deltaY > 0 ? 1 : -1) : 0;
			var dx = e.deltaX ? (e.deltaX > 0 ? 1 : -1) : 0;
			if (dy || dx) { pushEvent({ t: 'wheel', dy: dy, dx: dx }); }
		}, { capture: true, passive: false });

		document.addEventListener('keydown', function (e) {
			if (!R.on || !R.controlling) { return; }
			if (e.target && e.target.id === 'remote_input_type') { return; }
			if (e.key === 'Escape') {
				e.preventDefault();
				e.stopPropagation();
				release('Escape');
				return;
			}
			if (e.key === 'Control' || e.key === 'Shift' || e.key === 'Alt' || e.key === 'Meta') {
				return;
			}
			e.preventDefault();
			e.stopPropagation();
			var typedChar = typeFromKey(e);
			if (typedChar) { typed(typedChar); return; }
			var spec = keySpec(e);
			if (spec) { pushEvent({ t: 'key', k: spec }); }
		}, true);

		document.addEventListener('pointerlockchange', function () {
			R.locked = !!document.pointerLockElement;
			if (!R.locked && R.controlling && R.wantedLock) {
				release('lock ended');
			}
			else {
				paints();
			}
		});

		document.addEventListener('pointerlockerror', function () {
			R.wantedLock = false;
			paints();
		});

		$(document).on('change', '#remote_input_enabled', function () {
			R.on = $(this).is(':checked');
			R.lastError = '';
			clearQueue();
			R.uuid = selectedUuid();
			settingSetter({ app: 'me', setting: 'remote_control_input', value: R.on ? 'on' : 'off' });
			if (!R.on) { release('off'); }
			paints();
		});

		$(document).on('change', '#remote_input_edge', function () {
			R.edge = currentEdge();
			panel().attr('data-edge', R.edge);
			settingSetter({
				app: 'me', setting: 'remote_control_edge',
				subsetting: R.uuid, value: R.edge
			});
			R.returnArmed = false;
			paints();
		});

		$(document).on('click', '#remote_input_take', function (e) {
			e.preventDefault();
			R.edge = currentEdge();
			take();
		});

		$(document).on('click', '#remote_input_return', function (e) {
			e.preventDefault();
			release('button');
		});

		$(document).on('change', '#remote_control_machine_select', function () {
			// the panel re-renders for the new peer; never leave the old peer held
			if (R.controlling) { release('machine changed'); }
			R.uuid = $(this).val() || '';
			R.lastError = '';
			paints();
		});

		$(document).on('keydown', '#remote_input_type', function (e) {
			if (!R.controlling) { return; }
			if (e.key === 'Enter') {
				e.preventDefault();
				pushEvent({ t: 'key', k: 'Return' });
				$(this).val('');
			}
			else if (e.key === 'Escape') {
				e.preventDefault();
				release('Escape');
			}
			else if (e.key === 'Tab') {
				e.preventDefault();
				pushEvent({ t: 'key', k: 'Tab' });
			}
			else if (e.key === 'Backspace' && !$(this).val()) {
				e.preventDefault();
				pushEvent({ t: 'key', k: 'BackSpace' });
			}
			else if (e.key === 'ArrowUp' || e.key === 'ArrowDown' || e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
				e.preventDefault();
				var name = { ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right' }[e.key];
				pushEvent({ t: 'key', k: name });
			}
		});

		$(document).on('input', '#remote_input_type', function (e) {
			if (!R.controlling || e.originalEvent && e.originalEvent.isComposing) { return; }
			var text = $(this).val();
			$(this).val('');
			if (text) { typed(text); }
		});
	}

	// ---------------------------------------------------------------- entry

	window.jawnosRemoteInputInit = function () {
		bind();
		var p = panel();
		if (!p.length) { stop(); return; }
		var uuid = selectedUuid();
		if (R.controlling && uuid && R.uuid && uuid !== R.uuid) { release('machine changed'); }
		R.uuid = uuid;
		R.edge = currentEdge();
		R.on = $('#remote_input_enabled').is(':checked');
		R.lastError = '';
		$('#remote_input_edge').val(R.edge);
		$('#remote_input_take').prop('disabled', !R.on || !R.uuid);
		paints();
	};

	window.jawnosRemoteInputStop = function () { stop(); };
	window.jawnosRemoteInputRelease = function () { release('external'); };

	$(document).ready(function () {
		bind();
		if (panel().length) { window.jawnosRemoteInputInit(); }
	});
})();
