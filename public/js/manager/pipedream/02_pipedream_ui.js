function pipedreamInit() {
	if (typeof document === 'undefined' || !document.getElementById) { return; }
	var root = document.getElementById('pipedream');
	if (!root) { return; }
	if (root.getAttribute('data-pd-init') === '1') { return; }
	root.setAttribute('data-pd-init', '1');

	pipedreamStopTicker();
	pipedreamBindGlobal();

	var canvas = document.getElementById('pd_board');
	var c2d = canvas && canvas.getContext ? canvas.getContext('2d') : null;
	var stage = canvas ? canvas.parentNode : null;
	var statusEl = document.getElementById('pd_status');
	var handEl = document.getElementById('pd_hand');
	var startBtn = document.getElementById('pd_start');
	var rotateBtn = document.getElementById('pd_rotate');
	var undoBtn = document.getElementById('pd_undo');
	var newBtn = document.getElementById('pd_new');

	var seed = (Date.now() & 0x7fffffff) || 1;
	var state = pipedreamNewState(6, 5, seed);
	var selected = 0;
	var previewRot = 0;
	var cursor = { x: Math.min(1, state.cols - 1), y: state.source.y };
	var flowing = false;
	var cell = 40;
	var boardX = 0;
	var boardY = 0;
	var viewW = 0;
	var viewH = 0;
	var dpr = 1;
	var colors = {};

	function text(s) {
		if (typeof jawnosT === 'function') {
			try { return jawnosT(s); } catch (e) { /* keep the English */ }
		}
		return s;
	}

	function esc(s) {
		return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
			.replace(/>/g, '&gt;').replace(/"/g, '&quot;');
	}

	function touch() {
		if (typeof jawnosGameSessionStart === 'function' && pipedreamScreen()) {
			jawnosGameSessionStart('Pipedream', pipedreamScreen);
		}
	}

	function readColors() {
		var cs = null;
		try { cs = typeof window !== 'undefined' ? window.getComputedStyle(root) : null; } catch (e) { cs = null; }
		function v(name, fallback) {
			var got = cs && cs.getPropertyValue ? String(cs.getPropertyValue(name) || '').trim() : '';
			return got || fallback;
		}
		colors = {
			panel: v('--panel', '#ffffff'),
			panel2: v('--panel-2', '#f2f3f5'),
			line: v('--line', '#d7d9de'),
			ink: v('--ink', '#111417'),
			muted: v('--ink-muted', '#5b6169'),
			accent: v('--accent', '#3b7ddd'),
			accentLine: v('--accent-line', '#2f6cc4'),
			accentSoft: v('--accent-soft', '#e6effb'),
			accentInk: v('--accent-ink', '#ffffff'),
			good: v('--runway-good', '#2f7d4f'),
			bad: v('--runway-bad', '#b3453f')
		};
	}

	function stageSize() {
		var w = stage ? (stage.clientWidth || 0) : (root.clientWidth || 0);
		var h = stage ? (stage.clientHeight || 0) : (root.clientHeight || 0);
		if (typeof window !== 'undefined' && window.getComputedStyle && stage) {
			var cs = window.getComputedStyle(stage);
			w -= (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
			h -= (parseFloat(cs.paddingTop) || 0) + (parseFloat(cs.paddingBottom) || 0);
		}
		return { w: Math.max(0, w), h: Math.max(0, h) };
	}

	function fit() {
		if (!canvas || !c2d) { return; }
		var size = stageSize();
		if (size.w < 20 || size.h < 20) { return; }
		viewW = size.w;
		viewH = size.h;
		dpr = (typeof window !== 'undefined' && window.devicePixelRatio) || 1;
		canvas.width = Math.max(1, Math.round(viewW * dpr));
		canvas.height = Math.max(1, Math.round(viewH * dpr));
		canvas.style.width = viewW + 'px';
		canvas.style.height = viewH + 'px';
		var inset = Math.min(10, Math.max(4, Math.min(viewW, viewH) * 0.018));
		cell = Math.max(18, Math.floor(Math.min((viewW - inset * 2) / state.cols, (viewH - inset * 2) / state.rows)));
		boardX = Math.floor((viewW - cell * state.cols) / 2);
		boardY = Math.floor((viewH - cell * state.rows) / 2);
		readColors();
		draw();
	}

	function cellRect(x, y) {
		return { x: boardX + x * cell, y: boardY + y * cell, w: cell, h: cell };
	}

	function edgePoint(cx, cy, r, side, inset) {
		if (side === 0) { return { x: cx, y: r.y + inset }; }
		if (side === 1) { return { x: r.x + r.w - inset, y: cy }; }
		if (side === 2) { return { x: cx, y: r.y + r.h - inset }; }
		return { x: r.x + inset, y: cy };
	}

	function roundRect(c, x, y, w, h, r) {
		r = Math.min(r, w / 2, h / 2);
		c.beginPath();
		c.moveTo(x + r, y);
		c.arcTo(x + w, y, x + w, y + h, r);
		c.arcTo(x + w, y + h, x, y + h, r);
		c.arcTo(x, y + h, x, y, r);
		c.arcTo(x, y, x + w, y, r);
		c.closePath();
	}

	function strokeSides(cx, cy, r, sides, color, width) {
		c2d.strokeStyle = color;
		c2d.lineWidth = width;
		c2d.beginPath();
		for (var i = 0; i < sides.length; i++) {
			var p = edgePoint(cx, cy, r, sides[i], 0);
			c2d.moveTo(cx, cy);
			c2d.lineTo(p.x, p.y);
		}
		c2d.stroke();
	}

	function drawSource(cx, cy) {
		c2d.beginPath();
		c2d.arc(cx, cy, Math.max(6, cell * 0.2), 0, Math.PI * 2);
		c2d.fillStyle = colors.accent;
		c2d.fill();
		c2d.beginPath();
		c2d.arc(cx, cy, Math.max(3, cell * 0.08), 0, Math.PI * 2);
		c2d.fillStyle = colors.accentInk;
		c2d.fill();
	}

	function drawDrain(cx, cy) {
		c2d.beginPath();
		c2d.arc(cx, cy, Math.max(6, cell * 0.2), 0, Math.PI * 2);
		c2d.fillStyle = colors.panel;
		c2d.fill();
		c2d.lineWidth = Math.max(2, cell * 0.06);
		c2d.strokeStyle = colors.accentLine;
		c2d.stroke();
		c2d.beginPath();
		var bar = Math.max(4, cell * 0.12);
		for (var i = -1; i <= 1; i++) {
			c2d.moveTo(cx - bar, cy + i * bar * 0.62);
			c2d.lineTo(cx + bar, cy + i * bar * 0.62);
		}
		c2d.stroke();
	}

	function drawPiece(piece, x, y) {
		var r = cellRect(x, y);
		var cx = r.x + r.w / 2;
		var cy = r.y + r.h / 2;
		var sides = pipedreamPieceSides(piece);
		var wet = !!(state.wet[y] && state.wet[y][x]);
		var outer = Math.max(7, cell * 0.27);
		var inner = Math.max(4, cell * 0.15);
		c2d.lineCap = 'round';
		c2d.lineJoin = 'round';
		strokeSides(cx, cy, r, sides, colors.muted, outer);
		strokeSides(cx, cy, r, sides, wet ? colors.accent : colors.panel, inner);
		if (wet) {
			c2d.save();
			c2d.shadowColor = colors.accent;
			c2d.shadowBlur = cell * 0.22;
			strokeSides(cx, cy, r, sides, colors.accent, Math.max(2, inner * 0.55));
			c2d.restore();
		}
		if (piece.kind === 'source') { drawSource(cx, cy); }
		else if (piece.kind === 'drain') { drawDrain(cx, cy); }
	}

	function drawSpill() {
		var s = state.spillAt;
		if (!s) { return; }
		var r = cellRect(s.x, s.y);
		var cx = r.x + r.w / 2;
		var cy = r.y + r.h / 2;
		var p = edgePoint(cx, cy, r, s.side, 0);
		c2d.save();
		c2d.lineCap = 'round';
		c2d.strokeStyle = colors.bad;
		c2d.lineWidth = Math.max(3, cell * 0.1);
		c2d.beginPath();
		c2d.moveTo(cx, cy);
		c2d.lineTo(p.x, p.y);
		c2d.stroke();
		c2d.beginPath();
		c2d.arc(p.x, p.y, Math.max(4, cell * 0.14), 0, Math.PI * 2);
		c2d.fillStyle = colors.bad;
		c2d.fill();
		c2d.restore();
	}

	function drawBanner() {
		var bw = Math.min(cell * state.cols * 0.92, cell * 5.2);
		var bh = Math.min(cell * state.rows * 0.26, cell * 1.35);
		var bx = boardX + (cell * state.cols - bw) / 2;
		var by = boardY + cell * state.rows - bh - cell * 0.18;
		c2d.save();
		c2d.globalAlpha = 0.94;
		roundRect(c2d, bx, by, bw, bh, cell * 0.16);
		c2d.fillStyle = colors.panel;
		c2d.fill();
		c2d.globalAlpha = 1;
		c2d.lineWidth = Math.max(2, cell * 0.04);
		c2d.strokeStyle = state.won ? colors.good : colors.bad;
		c2d.stroke();
		c2d.textAlign = 'center';
		c2d.textBaseline = 'middle';
		c2d.fillStyle = state.won ? colors.good : colors.bad;
		c2d.font = '700 ' + Math.max(12, Math.floor(cell * 0.26)) + 'px system-ui, sans-serif';
		c2d.fillText(text(state.won ? 'Connected' : 'Spilled'), bx + bw / 2, by + bh * 0.36);
		c2d.fillStyle = colors.ink;
		c2d.font = '400 ' + Math.max(10, Math.floor(cell * 0.13)) + 'px system-ui, sans-serif';
		c2d.fillText(text(state.won ? 'Every drain is drinking.' : 'The water found an open end.'),
			bx + bw / 2, by + bh * 0.72);
		c2d.restore();
	}

	function draw() {
		if (!c2d || viewW < 10 || viewH < 10) { return; }
		c2d.setTransform(dpr, 0, 0, dpr, 0, 0);
		c2d.clearRect(0, 0, viewW, viewH);
		c2d.fillStyle = colors.panel;
		c2d.fillRect(0, 0, viewW, viewH);

		for (var y = 0; y < state.rows; y++) {
			for (var x = 0; x < state.cols; x++) {
				var r = cellRect(x, y);
				roundRect(c2d, r.x + 1.5, r.y + 1.5, r.w - 3, r.h - 3, Math.min(9, cell * 0.16));
				c2d.fillStyle = colors.panel2;
				c2d.fill();
				c2d.lineWidth = 1;
				c2d.strokeStyle = colors.line;
				c2d.stroke();
			}
		}

		if (!state.won && !state.spilled) {
			var cr = cellRect(cursor.x, cursor.y);
			roundRect(c2d, cr.x + 2.5, cr.y + 2.5, cr.w - 5, cr.h - 5, Math.min(9, cell * 0.16));
			c2d.lineWidth = Math.max(2, cell * 0.045);
			c2d.strokeStyle = colors.accent;
			c2d.stroke();
		}

		for (y = 0; y < state.rows; y++) {
			for (x = 0; x < state.cols; x++) {
				if (state.cells[y][x]) { drawPiece(state.cells[y][x], x, y); }
			}
		}

		if (!state.won && !state.spilled) {
			for (var f = 0; f < state.frontier.length; f++) {
				var fr = cellRect(state.frontier[f].x, state.frontier[f].y);
				c2d.beginPath();
				c2d.arc(fr.x + fr.w / 2, fr.y + fr.h / 2, Math.max(3, cell * 0.08), 0, Math.PI * 2);
				c2d.fillStyle = colors.accent;
				c2d.fill();
			}
		}

		if (state.spilled) { drawSpill(); }
		if (state.won || state.spilled) { drawBanner(); }
	}

	function svgFor(kind) {
		var d = kind === 'elbow' ? 'M20 34 V20 H34'
			: kind === 'tee' ? 'M20 6 V34 M20 20 H34'
			: 'M20 6 V34';
		return '<svg viewBox="0 0 40 40" aria-hidden="true"><path d="' + d
			+ '" fill="none" stroke="currentColor" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
	}

	function renderHand() {
		if (!handEl) { return; }
		var html = '';
		for (var i = 0; i < state.hand.length; i++) {
			var piece = state.hand[i];
			var cls = 'pd_hand_piece' + (piece.used ? ' used' : '') + (i === selected ? ' active' : '');
			var rot = (i === selected ? previewRot : 0) * 90;
			var label = piece.used ? text('Spent pipe') : text('Pipe') + ' ' + piece.kind;
			html += '<button type="button" class="' + cls + '" data-index="' + i + '" aria-label="' + esc(label) + '">'
				+ '<span class="pd_hand_icon" style="transform:rotate(' + rot + 'deg)">' + svgFor(piece.kind) + '</span>'
				+ '</button>';
		}
		handEl.innerHTML = html;
	}

	function leftCount() {
		var n = 0;
		for (var i = 0; i < state.hand.length; i++) { if (!state.hand[i].used) { n++; } }
		return n;
	}

	function updateStatus() {
		root.setAttribute('data-pd-state', state.won ? 'won' : state.spilled ? 'lost' : flowing ? 'flowing' : 'ready');
		if (statusEl) {
			var msg;
			if (state.won) { msg = text('Connected — every drain is drinking.'); }
			else if (state.spilled) { msg = text('Spilled — the water found an open end. Turn a pipe or lift it.'); }
			else if (flowing) { msg = text('The water is moving. Turn a pipe to change its way.'); }
			else if (!leftCount()) { msg = text('No pipes left. Start the flow or deal again.'); }
			else { msg = text('Place a pipe, turn it, then start the flow.'); }
			statusEl.textContent = msg;
		}
		if (startBtn) { startBtn.textContent = flowing ? text('Pause') : text('Start flow'); }
	}

	function refresh() {
		renderHand();
		updateStatus();
		draw();
	}

	function selectNext() {
		var i;
		for (i = selected + 1; i < state.hand.length; i++) {
			if (!state.hand[i].used) { selected = i; previewRot = 0; return; }
		}
		for (i = 0; i < state.hand.length; i++) {
			if (!state.hand[i].used) { selected = i; previewRot = 0; return; }
		}
		selected = -1;
		previewRot = 0;
	}

	function newDeal(nextSeed) {
		if (typeof nextSeed === 'number') { seed = nextSeed; }
		else { seed = (seed * 1664525 + 1013904223) >>> 0; }
		if (!seed) { seed = 1; }
		state = pipedreamNewState(6, 5, seed);
		flowing = false;
		pipedreamStopTicker();
		cursor = { x: Math.min(1, state.cols - 1), y: state.source.y };
		selected = 0;
		previewRot = 0;
		if (!state.hand[selected] || state.hand[selected].used) { selectNext(); }
		fit();
		refresh();
	}

	function toggleFlow() {
		if (flowing) {
			flowing = false;
			pipedreamStopTicker();
		}
		else {
			if (state.won || state.spilled) { pipedreamResetFlow(state); }
			flowing = true;
			ensureTicker();
		}
		refresh();
	}

	function tick() {
		if (!pipedreamScreen()) {
			flowing = false;
			pipedreamStopTicker();
			return;
		}
		if (!flowing) { return; }
		pipedreamStep(state);
		if (state.won || state.spilled) {
			flowing = false;
			pipedreamStopTicker();
		}
		refresh();
	}

	function ensureTicker() {
		if (pipedreamTicker) { return; }
		pipedreamTicker = setInterval(tick, 620);
	}

	function moveCursor(dx, dy) {
		cursor.x = Math.max(0, Math.min(state.cols - 1, cursor.x + dx));
		cursor.y = Math.max(0, Math.min(state.rows - 1, cursor.y + dy));
	}

	function placeOrRotate() {
		var piece = state.cells[cursor.y] && state.cells[cursor.y][cursor.x];
		if (piece) {
			if (!piece.fixed) { pipedreamRotate(state, cursor.x, cursor.y); }
		}
		else if (selected >= 0 && state.hand[selected] && !state.hand[selected].used) {
			if (pipedreamPlace(state, cursor.x, cursor.y, selected, previewRot)) { selectNext(); }
		}
		refresh();
	}

	function rotateAction() {
		var piece = state.cells[cursor.y] && state.cells[cursor.y][cursor.x];
		if (piece) {
			if (!piece.fixed) { pipedreamRotate(state, cursor.x, cursor.y); }
		}
		else {
			previewRot = (previewRot + 1) % 4;
		}
		refresh();
	}

	function selectHand(index) {
		if (index < 0 || index >= state.hand.length) { return; }
		if (state.hand[index].used) { return; }
		if (selected === index) { previewRot = (previewRot + 1) % 4; }
		else { selected = index; previewRot = 0; }
		refresh();
	}

	function pointCell(e) {
		if (!canvas) { return null; }
		var rect = canvas.getBoundingClientRect ? canvas.getBoundingClientRect() : { left: 0, top: 0 };
		var px = (e.clientX || 0) - rect.left;
		var py = (e.clientY || 0) - rect.top;
		var x = Math.floor((px - boardX) / cell);
		var y = Math.floor((py - boardY) / cell);
		if (x < 0 || y < 0 || x >= state.cols || y >= state.rows) { return null; }
		return { x: x, y: y };
	}

	function activeWindow() {
		if (typeof topWindow === 'function') {
			var name = topWindow();
			if (name && name !== 'pipedream') { return false; }
		}
		return true;
	}

	function key(e) {
		if (!activeWindow()) { return; }
		if (typeof document === 'undefined' || document.getElementById('pipedream') !== root) { return; }
		if (!pipedreamScreen()) { return; }
		var k = e.key || '';
		var code = e.keyCode || e.which || 0;
		var handled = true;
		if (k === 'ArrowLeft' || code === 37) { touch(); moveCursor(-1, 0); }
		else if (k === 'ArrowRight' || code === 39) { touch(); moveCursor(1, 0); }
		else if (k === 'ArrowUp' || code === 38) { touch(); moveCursor(0, -1); }
		else if (k === 'ArrowDown' || code === 40) { touch(); moveCursor(0, 1); }
		else if (k === 'r' || k === 'R' || code === 82) { touch(); rotateAction(); }
		else if (k === 'Enter' || k === ' ' || k === 'Spacebar' || code === 13 || code === 32) { touch(); placeOrRotate(); }
		else if (k === 'f' || k === 'F' || code === 70) { touch(); toggleFlow(); }
		else if (k === 'n' || k === 'N' || code === 78) { touch(); newDeal(); }
		else if (k === 'u' || k === 'U' || code === 85) { touch(); if (pipedreamUndo(state)) { selectNext(); } refresh(); }
		else if (code >= 49 && code <= 57) { touch(); selectHand(code - 49); }
		else { handled = false; }
		if (handled) {
			e.preventDefault();
			draw();
		}
	}

	// ---- wire the controls -------------------------------------------------
	root.addEventListener('pointerdown', function (e) {
		touch();
		if (e.target !== canvas) { return; }
		var c = pointCell(e);
		if (!c) { return; }
		cursor = c;
		var piece = state.cells[c.y][c.x];
		if (piece) {
			if (!piece.fixed) { pipedreamRotate(state, c.x, c.y); }
		}
		else if (selected >= 0 && state.hand[selected] && !state.hand[selected].used) {
			if (pipedreamPlace(state, c.x, c.y, selected, previewRot)) { selectNext(); }
		}
		refresh();
	});

	if (handEl) {
		handEl.addEventListener('click', function (e) {
			var el = e.target;
			while (el && el !== handEl) {
				if (el.hasAttribute && el.hasAttribute('data-index')) { break; }
				el = el.parentNode;
			}
			if (!el || el === handEl) { return; }
			touch();
			selectHand(parseInt(el.getAttribute('data-index'), 10));
		});
	}

	if (startBtn) { startBtn.addEventListener('click', function () { touch(); toggleFlow(); }); }
	if (rotateBtn) { rotateBtn.addEventListener('click', function () { touch(); rotateAction(); }); }
	if (undoBtn) {
		undoBtn.addEventListener('click', function () {
			touch();
			if (pipedreamUndo(state)) { selectNext(); }
			refresh();
		});
	}
	if (newBtn) { newBtn.addEventListener('click', function () { touch(); newDeal(); }); }

	if (typeof ResizeObserver === 'function' && stage) {
		try { new ResizeObserver(function () { fit(); }).observe(stage); } catch (e) { /* older engine */ }
	}
	if (typeof window !== 'undefined' && window.addEventListener) {
		window.addEventListener('resize', fit);
	}

	pipedreamGame = {
		root: root,
		key: key,
		pause: function () {
			flowing = false;
			pipedreamStopTicker();
			refresh();
		}
	};

	fit();
	// The window may be inserted before layout; a frame later the stage has a
	// size even if the first fit saw zero.
	if (typeof requestAnimationFrame === 'function') { requestAnimationFrame(fit); }
	else { setTimeout(fit, 50); }
	refresh();
}
