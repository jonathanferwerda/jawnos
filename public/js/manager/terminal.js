/* [[js-split]]
   terminal.js is part 1. The rest live in terminal/ in name order:
     01_render_input.js  - leave-alt/reset, render, fit/resize, input/key, scroll, views, shell and fonts
     02_events.js  - session/window lifecycle, receivers, status and document events
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
/* JawnOS Terminal -----------------------------------------------------------
   A small VT screen: ANSI/C0 parsing, a cell grid, scrollback, and the keys a
   pty expects. The old version printed key names ("Shift"), turned every CR
   into a new line, drew one span per cell and had no real scrollback. This one
   keeps a screen matrix, parses the sequences a shell and full-screen tools
   actually send, and renders runs instead of cells. */

/* Every Terminal window owns one state object and one server-side pty. The
   parser below still works on the active state in terminalVars; an entry point
   calls terminalUse(view) first, so two windows never share a screen. */
var terminalViews = {};
var terminalCurrentView = null;
var terminalWindowNumber = 0;
var terminalViewCounter = 0;

function terminalNewState() {
	return {
		cols: 80,
		rows: 24,
		grid: [],
		history: [],
		scrollOffset: 0,
		cursorX: 0,
		cursorY: 0,
		cursorVisible: true,
		savedX: 0,
		savedY: 0,
		scrollTop: 0,
		scrollBottom: 23,
		wrapPending: false,
		autowrap: true,
		appCursor: false,
		bracketedPaste: false,
		fg: -1,
		bg: -1,
		attrs: 0,
		lastChar: ' ',
		altGrid: null,
		altActive: false,
		parser: { state: 'ground', params: '', inter: '', osc: '' },
		decoder: null,
		raf: null,
		initialized: false,
		font: 15,
		cellW: 9,
		cellH: 20,
		styleCache: {},
		commandHistory: [],
		commandIndex: -1,
		touchY: null,
		composing: false,
		lastKnownState: ''
	};
}

var terminalVars = terminalNewState();

function terminalUse(view) {
	if (!view) { return null; }
	terminalCurrentView = view;
	terminalVars = view.state;
	return view;
}

function terminalViewFrom(el) {
	var node = el;
	if (!node || node.nodeType !== 1) { node = node && node.target; }
	if (!node || !node.closest) { return null; }
	var root = node.closest('.terminal_app');
	return root ? root.__terminalView : null;
}

function terminalEl(selector) {
	var root = terminalCurrentView && terminalCurrentView.root;
	return root ? root.querySelector(selector) : null;
}

function terminalRoot() {
	return terminalCurrentView ? terminalCurrentView.root : null;
}

function terminalNewId() {
	return 't' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

function terminalNewViewKey() {
	terminalViewCounter += 1;
	return 'v' + terminalViewCounter + '_' + Date.now().toString(36);
}

function terminalNextName() {
	terminalWindowNumber += 1;
	return terminalWord('Terminal') + ' ' + terminalWindowNumber;
}

var TERM_A_BOLD = 1, TERM_A_DIM = 2, TERM_A_ITALIC = 4, TERM_A_UNDER = 8,
	TERM_A_INVERSE = 16, TERM_A_STRIKE = 32, TERM_A_HIDDEN = 64;

var TERM_PALETTE = [
	'#1c1f26', '#ff5f56', '#5af78e', '#f3f99d', '#57c7ff', '#ff6ac1', '#9aedfe', '#f1f1f0',
	'#5c6370', '#ff8a80', '#8affc1', '#ffffa5', '#9ad9ff', '#ffa8d4', '#b7f7ff', '#ffffff'
];

function terminalEscape(text) {
	return String(text == null ? '' : text)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function terminalPad2(n) { return (n < 10 ? '0' : '') + n; }

function terminalWord(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function terminalBlankCell() { return { c: ' ', fg: -1, bg: -1, a: 0 }; }

function terminalBlankRow() {
	var row = new Array(terminalVars.cols);
	for (var x = 0; x < terminalVars.cols; x++) { row[x] = terminalBlankCell(); }
	return row;
}

function terminalColour(index, attrs) {
	if (index === -3) { return '#0b0e14'; }
	if (index === -2) { return '#d7dae0'; }
	if (typeof index === 'string') { return index; }
	if (attrs & TERM_A_BOLD && index < 8) { index += 8; }
	if (index < 16) { return TERM_PALETTE[index]; }
	if (index < 232) {
		var n = index - 16;
		var r = Math.floor(n / 36), g = Math.floor((n % 36) / 6), b = n % 6;
		var level = function (v) { return v === 0 ? 0 : 55 + v * 40; };
		return 'rgb(' + level(r) + ',' + level(g) + ',' + level(b) + ')';
	}
	if (index < 256) {
		var grey = 8 + (index - 232) * 10;
		return 'rgb(' + grey + ',' + grey + ',' + grey + ')';
	}
	return '';
}

function terminalStyleFor(cell) {
	var key = cell.fg + '|' + cell.bg + '|' + cell.a;
	var cached = terminalVars.styleCache[key];
	if (cached !== undefined) { return cached; }
	var fg = cell.fg, bg = cell.bg, a = cell.a;
	if (a & TERM_A_INVERSE) {
		var swap = fg;
		fg = (bg === -1) ? -3 : bg;
		bg = (swap === -1) ? -2 : swap;
	}
	var css = '';
	if (fg !== -1) { css += 'color:' + terminalColour(fg, a) + ';'; }
	if (bg !== -1) { css += 'background-color:' + terminalColour(bg, a) + ';'; }
	if (a & TERM_A_BOLD) { css += 'font-weight:700;'; }
	if (a & TERM_A_DIM) { css += 'opacity:.72;'; }
	if (a & TERM_A_ITALIC) { css += 'font-style:italic;'; }
	if (a & TERM_A_UNDER) { css += 'text-decoration:underline;'; }
	else if (a & TERM_A_STRIKE) { css += 'text-decoration:line-through;'; }
	if (a & TERM_A_HIDDEN) { css += 'visibility:hidden;'; }
	terminalVars.styleCache[key] = css;
	return css;
}

function terminalIsWide(ch) {
	var cp = ch.codePointAt(0);
	return (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0xA4CF)
		|| (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF)
		|| (cp >= 0xFE30 && cp <= 0xFE4F) || (cp >= 0xFF00 && cp <= 0xFF60)
		|| (cp >= 0xFFE0 && cp <= 0xFFE6) || (cp >= 0x1F300 && cp <= 0x1FAFF)
		|| (cp >= 0x20000 && cp <= 0x3FFFD);
}

function terminalIsCombining(ch) {
	return /^[\u0300-\u036f\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f]$/.test(ch);
}

/* ---- parser --------------------------------------------------------------- */

function terminalFeed(text) {
	var p = terminalVars.parser;
	for (var i = 0; i < text.length; i++) {
		var ch = text[i];
		var code = text.codePointAt(i);
		if (code > 0xffff) { ch = text.slice(i, i + 2); i++; }
		terminalConsume(ch);
	}
	terminalScheduleRender();
}

function terminalConsume(ch) {
	var p = terminalVars.parser;
	if (p.state === 'ground') { terminalGround(ch); return; }
	if (p.state === 'escape') { terminalEscapeState(ch); return; }
	if (p.state === 'csi') {
		if (ch === '\x1b') { p.state = 'escape'; return; }
		if (/[0-9;:?<>!=]/.test(ch)) { p.params += ch; return; }
		if (/[ -\/]/.test(ch)) { p.inter += ch; return; }
		if (/[@-~]/.test(ch)) {
			var final = ch;
			p.state = 'ground';
			terminalCsi(final, p.params, p.inter);
			p.params = ''; p.inter = '';
			return;
		}
		p.state = 'ground';
		p.params = ''; p.inter = '';
		return;
	}
	if (p.state === 'osc') {
		if (ch === '\x07') { terminalOsc(p.osc); p.osc = ''; p.state = 'ground'; return; }
		if (ch === '\x1b') { p.state = 'osc_esc'; return; }
		if (p.osc.length < 4096) { p.osc += ch; }
		return;
	}
	if (p.state === 'osc_esc') {
		terminalOsc(p.osc);
		p.osc = ''; p.state = (ch === '\\') ? 'ground' : 'ground';
		return;
	}
	if (p.state === 'string' || p.state === 'string_esc') {
		if (p.state === 'string' && ch === '\x1b') { p.state = 'string_esc'; return; }
		if (p.state === 'string_esc' && ch === '\\') { p.state = 'ground'; return; }
		p.state = 'string';
		return;
	}
	if (p.state === 'charset') { p.state = 'ground'; return; }
	p.state = 'ground';
}

function terminalGround(ch) {
	var c = ch.charCodeAt(0);
	if (ch === '\x1b') { terminalVars.parser.state = 'escape'; return; }
	if (ch === '\x9b') { terminalVars.parser.state = 'csi'; terminalVars.parser.params = ''; return; }
	if (ch === '\x9d') { terminalVars.parser.state = 'osc'; terminalVars.parser.osc = ''; return; }
	if (c === 0x07) { return; }
	if (c === 0x08) { terminalCursorLeft(1); return; }
	if (c === 0x09) { terminalTab(1); return; }
	if (c === 0x0a || c === 0x0b || c === 0x0c) {
		/* This pty runs raw (ONLCR is off), so a program's "\n" reaches us
		   without the carriage return a cooked terminal would add. Treat it
		   as one; a real CRLF still behaves the same because CR sets the
		   column to zero first. */
		terminalVars.cursorX = 0;
		terminalLineFeed();
		return;
	}
	if (c === 0x0d) { terminalVars.cursorX = 0; terminalVars.wrapPending = false; return; }
	if (c < 0x20) { return; }
	if (c === 0x7f) { return; }
	terminalPutChar(ch);
}

function terminalEscapeState(ch) {
	var p = terminalVars.parser;
	p.state = 'ground';
	if (ch === '[') { p.state = 'csi'; p.params = ''; p.inter = ''; return; }
	if (ch === ']') { p.state = 'osc'; p.osc = ''; return; }
	if (ch === 'P' || ch === '^' || ch === '_') { p.state = 'string'; return; }
	if (ch === '(' || ch === ')' || ch === '*' || ch === '+' || ch === '-' || ch === '.' || ch === '/') {
		p.state = 'charset'; return;
	}
	if (ch === '7') { terminalSaveCursor(); return; }
	if (ch === '8') { terminalRestoreCursor(); return; }
	if (ch === 'D') { terminalLineFeed(); return; }
	if (ch === 'E') { terminalVars.cursorX = 0; terminalLineFeed(); return; }
	if (ch === 'M') { terminalReverseIndex(); return; }
	if (ch === 'H') { return; }
	if (ch === 'c') { terminalReset(true); return; }
	if (ch === '=' || ch === '>' || ch === 'N' || ch === 'O') { return; }
}

function terminalOsc(text) {
	/* titles and hyperlinks are consumed; the shell owns its prompt */
}

function terminalParams(raw) {
	var prefix = '';
	var body = raw;
	if (/^[?<>!=]/.test(body)) { prefix = body.charAt(0); body = body.slice(1); }
	var list = body === '' ? [] : body.split(';');
	var n = [];
	for (var i = 0; i < list.length; i++) {
		var piece = list[i];
		var first = piece.split(':')[0];
		n.push(first === '' ? 0 : parseInt(first, 10) || 0);
	}
	return { prefix: prefix, list: n };
}

function terminalP(list, index, def) {
	if (index >= list.length) { return def; }
	var v = list[index];
	return v === 0 && def !== 0 ? def : v;
}

function terminalCsi(final, raw, inter) {
	var parsed = terminalParams(raw);
	var list = parsed.list;
	var n = function (i, def) { return terminalP(list, i, def); };
	var t = terminalVars;
	if (final === 'm') { terminalSgr(list); return; }
	if (final === 'A') { t.cursorY = Math.max(t.scrollTop, t.cursorY - n(0, 1)); t.wrapPending = false; return; }
	if (final === 'B' || final === 'e') { t.cursorY = Math.min(t.scrollBottom, t.cursorY + n(0, 1)); t.wrapPending = false; return; }
	if (final === 'C' || final === 'a') { t.cursorX = Math.min(t.cols - 1, t.cursorX + n(0, 1)); t.wrapPending = false; return; }
	if (final === 'D') { t.cursorX = Math.max(0, t.cursorX - n(0, 1)); t.wrapPending = false; return; }
	if (final === 'E') { t.cursorX = 0; t.cursorY = Math.min(t.scrollBottom, t.cursorY + n(0, 1)); t.wrapPending = false; return; }
	if (final === 'F') { t.cursorX = 0; t.cursorY = Math.max(t.scrollTop, t.cursorY - n(0, 1)); t.wrapPending = false; return; }
	if (final === 'G' || final === '`') { t.cursorX = Math.min(t.cols - 1, Math.max(0, n(0, 1) - 1)); t.wrapPending = false; return; }
	if (final === 'd') { t.cursorY = Math.min(t.rows - 1, Math.max(0, n(0, 1) - 1)); t.wrapPending = false; return; }
	if (final === 'H' || final === 'f') {
		t.cursorY = Math.min(t.rows - 1, Math.max(0, n(0, 1) - 1));
		t.cursorX = Math.min(t.cols - 1, Math.max(0, n(1, 1) - 1));
		t.wrapPending = false;
		return;
	}
	if (final === 'J') { terminalEraseDisplay(n(0, 0)); return; }
	if (final === 'K') { terminalEraseLine(n(0, 0)); return; }
	if (final === 'L') { terminalInsertLines(n(0, 1)); return; }
	if (final === 'M') { terminalDeleteLines(n(0, 1)); return; }
	if (final === '@') { terminalInsertChars(n(0, 1)); return; }
	if (final === 'P') { terminalDeleteChars(n(0, 1)); return; }
	if (final === 'X') { terminalEraseChars(n(0, 1)); return; }
	if (final === 'S') { terminalScrollUp(n(0, 1)); return; }
	if (final === 'T') { terminalScrollDown(n(0, 1)); return; }
	if (final === 'r') {
		var top = n(0, 1) - 1, bottom = n(1, t.rows) - 1;
		if (top >= 0 && bottom < t.rows && top < bottom) { t.scrollTop = top; t.scrollBottom = bottom; }
		else { t.scrollTop = 0; t.scrollBottom = t.rows - 1; }
		t.cursorX = 0; t.cursorY = t.scrollTop; t.wrapPending = false;
		return;
	}
	if (final === 's') { terminalSaveCursor(); return; }
	if (final === 'u') { terminalRestoreCursor(); return; }
	if (final === 'b') { for (var i = 0; i < n(0, 1); i++) { terminalPutChar(t.lastChar); } return; }
	if (final === 'h' || final === 'l') {
		var on = final === 'h';
		if (parsed.prefix === '?') {
			for (var j = 0; j < list.length; j++) { terminalPrivateMode(list[j], on); }
		}
		return;
	}
	if (final === 'n') {
		/* A terminal answers these: prompt libraries ask for the cursor position
		   or for the device's health and will wait for the reply. */
		if (n(0, 0) === 6) { terminalSendInput('\x1b[' + (t.cursorY + 1) + ';' + (t.cursorX + 1) + 'R'); }
		else if (n(0, 0) === 5) { terminalSendInput('\x1b[0n'); }
		return;
	}
	if (final === 'c') {
		if (parsed.prefix === '>') { terminalSendInput('\x1b[>0;1;0c'); }
		else { terminalSendInput('\x1b[?1;2c'); }
		return;
	}
	if (final === 'q' || final === 't' || final === 'g' || final === 'p') { return; }
}

function terminalPrivateMode(mode, on) {
	var t = terminalVars;
	if (mode === 25) { t.cursorVisible = on; return; }
	if (mode === 7) { t.autowrap = on; return; }
	if (mode === 1) { t.appCursor = on; return; }
	if (mode === 2004) { t.bracketedPaste = on; return; }
	if (mode === 47 || mode === 1047 || mode === 1049) {
		if (on && !t.altActive) { terminalEnterAlt(mode === 1049); }
		else if (!on && t.altActive) { terminalLeaveAlt(); }
		return;
	}
	if (mode === 1048) { if (on) { terminalSaveCursor(); } else { terminalRestoreCursor(); } return; }
}

function terminalSgr(list) {
	var t = terminalVars;
	if (!list.length) { list = [0]; }
	for (var i = 0; i < list.length; i++) {
		var n = list[i];
		if (n === 0) { t.fg = -1; t.bg = -1; t.attrs = 0; }
		else if (n === 1) { t.attrs |= TERM_A_BOLD; }
		else if (n === 2) { t.attrs |= TERM_A_DIM; }
		else if (n === 3) { t.attrs |= TERM_A_ITALIC; }
		else if (n === 4) { t.attrs |= TERM_A_UNDER; }
		else if (n === 7) { t.attrs |= TERM_A_INVERSE; }
		else if (n === 8) { t.attrs |= TERM_A_HIDDEN; }
		else if (n === 9) { t.attrs |= TERM_A_STRIKE; }
		else if (n === 21 || n === 22) { t.attrs &= ~(TERM_A_BOLD | TERM_A_DIM); }
		else if (n === 23) { t.attrs &= ~TERM_A_ITALIC; }
		else if (n === 24) { t.attrs &= ~TERM_A_UNDER; }
		else if (n === 27) { t.attrs &= ~TERM_A_INVERSE; }
		else if (n === 28) { t.attrs &= ~TERM_A_HIDDEN; }
		else if (n === 29) { t.attrs &= ~TERM_A_STRIKE; }
		else if (n >= 30 && n <= 37) { t.fg = n - 30; }
		else if (n === 38 || n === 48) {
			var target = (n === 38) ? 'fg' : 'bg';
			if (list[i + 1] === 5 && i + 2 < list.length) { t[target] = list[i + 2]; i += 2; }
			else if (list[i + 1] === 2 && i + 4 < list.length) {
				t[target] = 'rgb(' + list[i + 2] + ',' + list[i + 3] + ',' + list[i + 4] + ')';
				i += 4;
			}
		}
		else if (n === 39) { t.fg = -1; }
		else if (n >= 40 && n <= 47) { t.bg = n - 40; }
		else if (n === 49) { t.bg = -1; }
		else if (n >= 90 && n <= 97) { t.fg = n - 90 + 8; }
		else if (n >= 100 && n <= 107) { t.bg = n - 100 + 8; }
	}
}

/* ---- screen operations ---------------------------------------------------- */

function terminalPutChar(ch) {
	var t = terminalVars;
	if (t.cursorY < 0) { t.cursorY = 0; }
	if (t.cursorY >= t.rows) { t.cursorY = t.rows - 1; }
	if (terminalIsCombining(ch)) {
		var prev = t.grid[t.cursorY] && t.grid[t.cursorY][Math.max(0, t.cursorX - 1)];
		if (prev) { prev.c += ch; }
		terminalScheduleRender();
		return;
	}
	var width = terminalIsWide(ch) ? 2 : 1;
	if (t.wrapPending) {
		t.cursorX = 0;
		terminalLineFeed();
		t.wrapPending = false;
	}
	if (t.cursorX + width > t.cols) {
		t.cursorX = 0;
		terminalLineFeed();
	}
	var row = t.grid[t.cursorY];
	if (!row) { return; }
	var cell = row[t.cursorX];
	if (!cell) { cell = row[t.cursorX] = terminalBlankCell(); }
	cell.c = ch;
	cell.fg = t.fg; cell.bg = t.bg; cell.a = t.attrs;
	if (width === 2) {
		if (t.cursorX + 1 < t.cols) {
			row[t.cursorX + 1] = { c: '', fg: t.fg, bg: t.bg, a: t.attrs, cont: 1 };
		}
		t.cursorX += 2;
	}
	else { t.cursorX += 1; }
	t.lastChar = ch;
	if (t.cursorX >= t.cols) {
		t.cursorX = t.cols - 1;
		t.wrapPending = t.autowrap;
	}
}

function terminalLineFeed() {
	var t = terminalVars;
	if (t.cursorY === t.scrollBottom) {
		var removed = t.grid.splice(t.scrollTop, 1)[0];
		t.grid.splice(t.scrollBottom, 0, terminalBlankRow());
		if (t.scrollTop === 0 && t.scrollBottom === t.rows - 1 && !t.altActive) {
			t.history.push(removed);
			if (t.history.length > 2000) { t.history.shift(); }
			/* Keep what the reader is looking at still: the bottom moved down a
			   line, so the same window is one line further up from it. */
			if (t.scrollOffset > 0) { t.scrollOffset++; }
		}
	}
	else if (t.cursorY < t.rows - 1) { t.cursorY++; }
	t.wrapPending = false;
}

function terminalReverseIndex() {
	var t = terminalVars;
	if (t.cursorY === t.scrollTop) {
		t.grid.splice(t.scrollBottom, 1);
		t.grid.splice(t.scrollTop, 0, terminalBlankRow());
	}
	else if (t.cursorY > 0) { t.cursorY--; }
	t.wrapPending = false;
}

function terminalCursorLeft(n) {
	var t = terminalVars;
	t.cursorX = Math.max(0, t.cursorX - (n || 1));
	t.wrapPending = false;
}

function terminalTab(n) {
	var t = terminalVars;
	for (var i = 0; i < (n || 1); i++) {
		t.cursorX = Math.min(t.cols - 1, (Math.floor(t.cursorX / 8) + 1) * 8);
	}
	t.wrapPending = false;
}

function terminalEraseLine(mode) {
	var t = terminalVars;
	var row = t.grid[t.cursorY];
	if (!row) { return; }
	var from = 0, to = t.cols - 1;
	if (mode === 0) { from = t.cursorX; }
	else if (mode === 1) { to = t.cursorX; }
	for (var x = from; x <= to; x++) { row[x] = terminalBlankCell(); }
}

function terminalEraseDisplay(mode) {
	var t = terminalVars;
	if (mode === 0) {
		terminalEraseLine(0);
		for (var y = t.cursorY + 1; y < t.rows; y++) { t.grid[y] = terminalBlankRow(); }
	}
	else if (mode === 1) {
		terminalEraseLine(1);
		for (var y2 = 0; y2 < t.cursorY; y2++) { t.grid[y2] = terminalBlankRow(); }
	}
	else {
		for (var y3 = 0; y3 < t.rows; y3++) { t.grid[y3] = terminalBlankRow(); }
		t.cursorX = 0; t.cursorY = 0;
		if (mode === 3) { t.history = []; t.scrollOffset = 0; }
	}
	t.wrapPending = false;
}

function terminalInsertLines(n) {
	var t = terminalVars;
	if (t.cursorY < t.scrollTop || t.cursorY > t.scrollBottom) { return; }
	for (var i = 0; i < n; i++) {
		t.grid.splice(t.cursorY, 0, terminalBlankRow());
		t.grid.splice(t.scrollBottom + 1, 1);
	}
}

function terminalDeleteLines(n) {
	var t = terminalVars;
	if (t.cursorY < t.scrollTop || t.cursorY > t.scrollBottom) { return; }
	for (var i = 0; i < n; i++) {
		t.grid.splice(t.cursorY, 1);
		t.grid.splice(t.scrollBottom, 0, terminalBlankRow());
	}
}

function terminalInsertChars(n) {
	var t = terminalVars;
	var row = t.grid[t.cursorY];
	if (!row) { return; }
	for (var i = 0; i < n; i++) {
		row.splice(t.cursorX, 0, terminalBlankCell());
		row.splice(t.cols, 1);
	}
}

function terminalDeleteChars(n) {
	var t = terminalVars;
	var row = t.grid[t.cursorY];
	if (!row) { return; }
	for (var i = 0; i < n; i++) {
		row.splice(t.cursorX, 1);
		row.push(terminalBlankCell());
	}
}

function terminalEraseChars(n) {
	var t = terminalVars;
	var row = t.grid[t.cursorY];
	if (!row) { return; }
	for (var i = 0; i < n && t.cursorX + i < t.cols; i++) { row[t.cursorX + i] = terminalBlankCell(); }
}

function terminalScrollUp(n) {
	var t = terminalVars;
	for (var i = 0; i < n; i++) {
		t.grid.splice(t.scrollTop, 1);
		t.grid.splice(t.scrollBottom, 0, terminalBlankRow());
	}
}

function terminalScrollDown(n) {
	var t = terminalVars;
	for (var i = 0; i < n; i++) {
		t.grid.splice(t.scrollBottom, 1);
		t.grid.splice(t.scrollTop, 0, terminalBlankRow());
	}
}

function terminalSaveCursor() {
	terminalVars.savedX = terminalVars.cursorX;
	terminalVars.savedY = terminalVars.cursorY;
}

function terminalRestoreCursor() {
	terminalVars.cursorX = Math.min(terminalVars.cols - 1, Math.max(0, terminalVars.savedX));
	terminalVars.cursorY = Math.min(terminalVars.rows - 1, Math.max(0, terminalVars.savedY));
	terminalVars.wrapPending = false;
}

function terminalEnterAlt(saveCursor) {
	var t = terminalVars;
	if (t.altActive) { return; }
	t.altGrid = t.grid;
	if (saveCursor) { terminalSaveCursor(); }
	t.grid = [];
	for (var y = 0; y < t.rows; y++) { t.grid.push(terminalBlankRow()); }
	t.altActive = true;
	t.scrollOffset = 0;
	t.cursorX = 0; t.cursorY = 0;
	t.scrollTop = 0; t.scrollBottom = t.rows - 1;
}

