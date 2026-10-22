/* JawnOS Terminal -----------------------------------------------------------
   A small VT screen: ANSI/C0 parsing, a cell grid, scrollback, and the keys a
   pty expects. The old version printed key names ("Shift"), turned every CR
   into a new line, drew one span per cell and had no real scrollback. This one
   keeps a screen matrix, parses the sequences a shell and full-screen tools
   actually send, and renders runs instead of cells. */

var terminalVars = {
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
	observer: null,
	touchY: null,
	lastKnownState: ''
};

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

function terminalLeaveAlt() {
	var t = terminalVars;
	if (!t.altActive) { return; }
	t.grid = t.altGrid || [];
	t.altGrid = null;
	t.altActive = false;
	while (t.grid.length < t.rows) { t.grid.push(terminalBlankRow()); }
	t.cursorX = Math.min(t.cols - 1, Math.max(0, t.savedX));
	t.cursorY = Math.min(t.rows - 1, Math.max(0, t.savedY));
	t.scrollTop = 0; t.scrollBottom = t.rows - 1;
	t.scrollOffset = 0;
}

function terminalReset(hard) {
	var t = terminalVars;
	t.grid = [];
	for (var y = 0; y < t.rows; y++) { t.grid.push(terminalBlankRow()); }
	if (hard) { t.history = []; }
	t.cursorX = 0; t.cursorY = 0;
	t.savedX = 0; t.savedY = 0;
	t.scrollTop = 0; t.scrollBottom = t.rows - 1;
	t.wrapPending = false;
	t.fg = -1; t.bg = -1; t.attrs = 0;
	t.appCursor = false; t.bracketedPaste = false;
	t.altGrid = null; t.altActive = false;
	t.scrollOffset = 0;
	t.parser.state = 'ground'; t.parser.params = ''; t.parser.inter = ''; t.parser.osc = '';
	t.styleCache = {};
}

/* ---- rendering ------------------------------------------------------------ */

function terminalScheduleRender() {
	if (terminalVars.raf) { return; }
	terminalVars.raf = window.requestAnimationFrame(function () {
		terminalVars.raf = null;
		terminalRender();
	});
}

function terminalRowHtml(row, cursorX) {
	var out = '', text = '', style = null, cursor = false;
	var flush = function () {
		if (text === '' && !cursor) { return; }
		var html = '<span';
		if (style) { html += ' style="' + style + '"'; }
		if (cursor) { html += ' class="term-cursor"'; }
		html += '>' + terminalEscape(text === '' ? ' ' : text) + '</span>';
		out += html;
		text = ''; cursor = false;
	};
	for (var x = 0; x < terminalVars.cols; x++) {
		var cell = row[x];
		if (!cell) { cell = terminalBlankCell(); }
		if (cell.cont) { continue; }
		var st = terminalStyleFor(cell);
		var cur = (x === cursorX);
		if (st !== style || cur !== cursor) { flush(); style = st; cursor = cur; }
		text += cell.c || ' ';
	}
	flush();
	return out === '' ? '&nbsp;' : out;
}

function terminalRender() {
	var screen = document.getElementById('terminal_screen');
	if (!screen) { return; }
	var t = terminalVars;
	var offset = Math.min(t.scrollOffset, t.history.length);
	var historyLength = t.history.length;
	var total = historyLength + t.grid.length;
	var start = total - t.rows - offset;
	if (start < 0) { start = 0; }
	var cursorRow = historyLength + t.cursorY;
	var html = '';
	for (var y = 0; y < t.rows; y++) {
		var index = start + y;
		var row = index < historyLength ? t.history[index] : t.grid[index - historyLength];
		if (!row) { row = terminalBlankRow(); }
		var cursorX = -1;
		if (offset === 0 && t.cursorVisible && !t.altActive && index === cursorRow) { cursorX = t.cursorX; }
		html += '<div class="term-line">' + terminalRowHtml(row, cursorX) + '</div>';
	}
	screen.innerHTML = html;
	if (t.cellH) { screen.style.setProperty('--term-line-height', t.cellH.toFixed(2) + 'px'); }
	var jump = document.getElementById('terminal_jump');
	if (jump) { jump.setAttribute('data-show', offset > 0 ? 'yes' : 'no'); }
}

/* ---- sizing --------------------------------------------------------------- */

function terminalMeasure() {
	var screen = document.getElementById('terminal_screen');
	if (!screen) { return { w: 9, h: 20 }; }
	var cs = window.getComputedStyle(screen);
	var probe = document.createElement('span');
	probe.textContent = 'MMMMMMMMMMMMMMMMMMMM';
	probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre;left:-9999px;top:0;letter-spacing:0;'
		+ 'font-family:' + cs.fontFamily + ';font-size:' + cs.fontSize + ';font-weight:' + cs.fontWeight + ';';
	document.body.appendChild(probe);
	var w = probe.getBoundingClientRect().width / 20;
	probe.parentNode.removeChild(probe);
	var h = parseFloat(cs.lineHeight);
	if (!h || isNaN(h)) {
		var size = parseFloat(cs.fontSize) || terminalVars.font;
		h = size * 1.32;
	}
	return { w: w > 0 ? w : 8, h: h > 0 ? h : 20 };
}

function terminalFit(force) {
	var wrap = document.getElementById('terminal_interactive');
	if (!wrap || !$('#terminal_interactive').is(':visible')) { return; }
	var rect = wrap.getBoundingClientRect();
	if (rect.width < 20 || rect.height < 20) { return; }
	var cs = window.getComputedStyle(wrap);
	var padX = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
	var padY = (parseFloat(cs.paddingTop) || 0) + (parseFloat(cs.paddingBottom) || 0);
	var m = terminalMeasure();
	terminalVars.cellW = m.w;
	terminalVars.cellH = m.h;
	var cols = Math.max(20, Math.floor((rect.width - padX) / m.w));
	var rows = Math.max(4, Math.floor((rect.height - padY) / m.h));
	if (cols === terminalVars.cols && rows === terminalVars.rows && !force) { return; }
	terminalResize(cols, rows);
}

function terminalResize(cols, rows) {
	var t = terminalVars;
	var oldRows = t.rows;
	var oldGrid = t.grid;
	var newGrid = [];
	for (var y = 0; y < rows; y++) {
		var source = oldRows - rows + y;
		var sourceRow = (source >= 0) ? oldGrid[source] : null;
		if (t.altActive) { sourceRow = null; }
		var row = new Array(cols);
		for (var x = 0; x < cols; x++) {
			var cell = sourceRow && sourceRow[x];
			row[x] = cell ? { c: cell.c, fg: cell.fg, bg: cell.bg, a: cell.a, cont: cell.cont } : terminalBlankCell();
		}
		newGrid.push(row);
	}
	t.cols = cols;
	t.rows = rows;
	t.grid = newGrid;
	t.cursorY = Math.max(0, Math.min(rows - 1, t.cursorY - (oldRows - rows)));
	t.cursorX = Math.max(0, Math.min(cols - 1, t.cursorX));
	t.scrollTop = 0;
	t.scrollBottom = rows - 1;
	t.scrollOffset = 0;
	t.wrapPending = false;
	terminalRender();
	terminalSend({ type: 'terminal_resize', rows: rows, cols: cols });
}

/* ---- input ---------------------------------------------------------------- */

function terminalSend(data) {
	if (!data) { return; }
	data['app'] = 'server';
	if (typeof ws === 'undefined' || !ws['server'] || ws['server'].readyState !== 1) { return; }
	ws['server'].send(JSON.stringify(data));
}

function terminalSendInput(text) {
	if (text === undefined || text === null || text === '') { return; }
	terminalSend({ pty: 'yes', type: 'input', input: text });
	if (terminalVars.scrollOffset !== 0) { terminalScrollBottom(); }
}

function terminalKeyData(e) {
	if (e.defaultPrevented) { return null; }
	if (e.isComposing || e.key === 'Process' || e.keyCode === 229) { return null; }
	var key = e.key;
	/* Leave browser and desktop shortcuts alone. A terminal on the web should
	   not swallow Cmd+C, Alt+Tab or the browser's own Ctrl+W. */
	if (e.metaKey && !e.ctrlKey) { return null; }
	if (e.ctrlKey && e.shiftKey && (key === 'C' || key === 'V' || key === 'X' || key === 'A')) { return null; }
	var mod = 1 + (e.shiftKey ? 1 : 0) + (e.altKey ? 2 : 0) + (e.ctrlKey ? 4 : 0) + (e.metaKey ? 8 : 0);
	var csi = function (base, oneBased) {
		if (mod === 1) { return oneBased ? '\x1b[' + base + '~' : '\x1b[' + base; }
		return '\x1b[' + (oneBased ? base : '1') + ';' + mod + (oneBased ? '~' : base);
	};
	var seq = null;
	switch (key) {
		case 'Enter': case 'Return': seq = e.altKey ? '\x1b\r' : '\r'; break;
		case 'Backspace': seq = e.ctrlKey ? '\x17' : '\x7f'; break;
		case 'Tab': seq = e.shiftKey ? '\x1b[Z' : '\t'; break;
		case 'Escape': case 'Esc': seq = '\x1b'; break;
		case 'Delete': case 'Del': seq = csi('3', true); break;
		case 'Insert': seq = csi('2', true); break;
		case 'Home': seq = terminalVars.appCursor ? '\x1bOH' : csi('H', false); break;
		case 'End': seq = terminalVars.appCursor ? '\x1bOF' : csi('F', false); break;
		case 'PageUp': seq = csi('5', true); break;
		case 'PageDown': seq = csi('6', true); break;
		case 'ArrowUp': seq = (mod === 1 && terminalVars.appCursor) ? '\x1bOA' : csi('A', false); break;
		case 'ArrowDown': seq = (mod === 1 && terminalVars.appCursor) ? '\x1bOB' : csi('B', false); break;
		case 'ArrowRight': seq = (mod === 1 && terminalVars.appCursor) ? '\x1bOC' : csi('C', false); break;
		case 'ArrowLeft': seq = (mod === 1 && terminalVars.appCursor) ? '\x1bOD' : csi('D', false); break;
		case 'F1': seq = '\x1bOP'; break;
		case 'F2': seq = '\x1bOQ'; break;
		case 'F3': seq = '\x1bOR'; break;
		case 'F4': seq = '\x1bOS'; break;
		case 'F5': seq = csi('15', true); break;
		case 'F6': seq = csi('17', true); break;
		case 'F7': seq = csi('18', true); break;
		case 'F8': seq = csi('19', true); break;
		case 'F9': seq = csi('20', true); break;
		case 'F10': seq = csi('21', true); break;
		case 'F11': seq = csi('23', true); break;
		case 'F12': seq = csi('24', true); break;
	}
	if (seq !== null) {
		e.preventDefault();
		return seq;
	}
	if (e.ctrlKey && !e.altKey && key.length === 1) {
		var up = key.toUpperCase();
		var code = up.charCodeAt(0);
		if (code >= 64 && code <= 95) {
			e.preventDefault();
			return String.fromCharCode(code - 64);
		}
		if (key === ' ') { e.preventDefault(); return '\x00'; }
		if (key === '[') { e.preventDefault(); return '\x1b'; }
		if (key === '\\') { e.preventDefault(); return '\x1c'; }
		if (key === ']') { e.preventDefault(); return '\x1d'; }
		if (key === '^') { e.preventDefault(); return '\x1e'; }
		if (key === '_') { e.preventDefault(); return '\x1f'; }
		if (key === '?') { e.preventDefault(); return '\x7f'; }
	}
	if (key.length === 1 || (key.codePointAt(0) || 0) > 0xffff) {
		e.preventDefault();
		return (e.altKey ? '\x1b' : '') + key;
	}
	/* A lone modifier key is not input: returning null here is what keeps
	   "Shift" and "Control" out of the command line. */
	return null;
}

/* ---- fitting, views and the chrome ---------------------------------------- */

function terminalScrollBottom() {
	terminalVars.scrollOffset = 0;
	terminalRender();
}

function terminalNearBottom(el) {
	return el.scrollHeight - el.scrollTop - el.clientHeight < 48;
}

function terminalScrollList(container) {
	var el = document.getElementById(container);
	if (el) { el.scrollTop = el.scrollHeight; }
}

function terminalScrollListsBottom() {
	terminalScrollList('terminal_error_entries');
	terminalScrollList('terminal_log_entries');
	terminalScrollList('terminal_command_output');
}

function terminalStampTimes(root) {
	$(root).find('.terminal_entry_time[data-ts]').each(function () {
		var ts = parseInt($(this).attr('data-ts'), 10);
		if (!ts) { return; }
		if (ts < 100000000000) { ts *= 1000; }
		var d = new Date(ts);
		var now = new Date();
		var when = terminalPad2(d.getHours()) + ':' + terminalPad2(d.getMinutes()) + ':' + terminalPad2(d.getSeconds());
		if (d.toDateString() !== now.toDateString()) {
			when = (d.getMonth() + 1) + '/' + d.getDate() + ' ' + when;
		}
		$(this).text(when);
	});
}

function terminalSetView(view, persist) {
	var t = document.getElementById('terminal');
	if (!t || !view) { return; }
	$('#terminal .terminal_view').css('display', 'none');
	$('#terminal .terminal_view[view="' + view + '"]').css('display', 'flex');
	$('#terminal .terminal_view_select').removeAttr('selected').attr('aria-selected', 'false');
	$('#terminal .terminal_view_select[view="' + view + '"]').attr('selected', 'selected').attr('aria-selected', 'true');
	if (persist) {
		settingSetter({ app: 'terminal', setting: 'view', value: view });
	}
	if (view === 'interactive_terminal') {
		terminalFit(true);
		terminalFocusKeyboard();
	}
	else if (view === 'terminal') {
		$('#terminal_console').trigger('focus');
		terminalScrollList('terminal_command_output');
	}
	else {
		terminalStampTimes(document);
		setTimeout(function () {
			terminalScrollList(view === 'errors' ? 'terminal_error_entries' : 'terminal_log_entries');
		}, 0);
	}
}

function terminalFocusKeyboard() {
	var k = document.getElementById('terminal_keyboard');
	if (!k) { return; }
	try { k.focus({ preventScroll: true }); } catch (e) { k.focus(); }
}

function terminalShellStatus(info) {
	if (!info) { return; }
	var t = document.getElementById('terminal');
	if (!t) { return; }
	var state = info['state'] || 'live';
	var label = info['label'] || '';
	var dot = document.getElementById('terminal_shell_dot');
	if (dot) {
		dot.className = 'terminal_dot ' + (state === 'connecting' ? 'connecting'
			: state === 'ended' ? 'ended'
			: state === 'local' ? 'local'
			: (info['local'] ? 'local' : 'remote'));
	}
	var suffix = state === 'connecting' ? ' · ' + terminalWord('connecting')
		: state === 'ended' ? ' · ' + terminalWord('ended') : '';
	$('#terminal_shell_status').text(label + suffix).attr('title', (info['message'] || label));
	if (label) {
		t.setAttribute('data-shell-label', label);
	}
	$('#terminal .terminal_local_connect').removeClass('current');
	$('#terminal .terminal_remote_row').removeClass('current');
	if (state === 'local' || info['local']) {
		$('#terminal .terminal_local_connect').addClass('current');
	}
	else if (info['host']) {
		$('#terminal .terminal_remote_row[data-host="' + info['host'] + '"]').addClass('current');
	}
	terminalVars.lastKnownState = state;
}

function terminalShellConnect(host, user, port) {
	host = host || '';
	user = user || '';
	port = port || '';
	var label = host ? ((user ? user + '@' : '') + host) : '';
	terminalReset(true);
	terminalRender();
	terminalShellStatus({ state: host ? 'connecting' : 'local', label: label, local: !host });
	terminalSend(host
		? { type: 'terminal_connect', host: host, user: user, port: port }
		: { type: 'terminal_local' });
	terminalSetView('interactive_terminal', true);
	terminalFocusKeyboard();
}

function terminalSaveRemotes() {
	var map = {};
	$('#terminal .terminal_remote_row').each(function () {
		var key = $(this).attr('data-key') || $(this).attr('data-host');
		if (!key) { return; }
		map[key] = {
			user: $.trim($(this).find('.terminal_remote_user').val() || ''),
			port: $.trim($(this).find('.terminal_remote_port').val() || '')
		};
	});
	settingSetter({ app: 'terminal', setting: 'remotes', value: JSON.stringify(map) });
}

function terminalSetFont(size) {
	size = parseInt(size, 10);
	if (!(size >= 10 && size <= 32)) { return; }
	terminalVars.font = size;
	var el = document.getElementById('terminal');
	if (el) { el.style.setProperty('--terminal_font', size + 'px'); }
	$('#terminal_font_size').text(size);
	terminalFit(true);
	settingSetter({ app: 'terminal', setting: 'font_size', value: size });
}

function terminalEntryHtml(kind, item, whoami, hostname) {
	item = item || {};
	var msg = item['msg'] != null ? String(item['msg']) : '';
	msg = msg.replace(/<br\s*\/?>/gi, '\n');
	var ts = item['timestamp'] || '';
	var when = '';
	var n = parseInt(ts, 10);
	if (n) {
		if (n < 100000000000) { n *= 1000; }
		var d = new Date(n);
		when = terminalPad2(d.getHours()) + ':' + terminalPad2(d.getMinutes()) + ':' + terminalPad2(d.getSeconds());
	}
	var kindClass = kind === 'error' ? 'terminal_entry_error' : (kind === 'log' ? 'terminal_entry_log' : 'terminal_entry_command');
	var uid = item['uuid'] || '';
	var full = msg;
	var trimmed = full.length > 1400;
	var preview = trimmed ? full.slice(0, 1400) : full;
	var more = trimmed
		? '<details class="terminal_entry_more"><summary>'
			+ terminalEscape(typeof jawnosT === 'function' ? jawnosT('Show the full message') : 'Show the full message')
			+ '</summary><div class="terminal_entry_msg">' + terminalEscape(full) + '</div></details>'
		: '';
	return '<div class="terminal_entry ' + kindClass + '"' + (uid ? ' data-uuid="' + terminalEscape(uid) + '"' : '') + '>'
		+ '<div class="terminal_entry_head">'
		+ '<span class="terminal_entry_time" data-ts="' + terminalEscape(ts) + '">' + terminalEscape(when) + '</span>'
		+ (kind === 'log' ? '<span class="terminal_entry_code">' + terminalEscape(terminalWord('log')) + '</span>' : (item['code'] ? '<span class="terminal_entry_code">' + terminalEscape(item['code']) + '</span>' : ''))
		+ (whoami ? '<span class="terminal_entry_who">' + terminalEscape(whoami + (hostname ? '@' + hostname : '')) + '</span>' : '')
		+ '</div>'
		+ '<div class="terminal_entry_msg">' + terminalEscape(preview) + (trimmed ? '&#8230;' : '') + '</div>'
		+ more
		+ '</div>';
}

function terminalAppendTo(containerId, html, badgeId) {
	var box = document.getElementById(containerId);
	if (!box) { return; }
	var atBottom = terminalNearBottom(box);
	var empty = box.querySelector('.terminal_empty');
	if (empty) { empty.parentNode.removeChild(empty); }
	box.insertAdjacentHTML('beforeend', html);
	if (box.lastElementChild) { terminalStampTimes(box.lastElementChild); }
	if (atBottom) { box.scrollTop = box.scrollHeight; }
	if (badgeId) {
		var badge = document.getElementById(badgeId);
		if (badge) { badge.textContent = (parseInt(badge.textContent, 10) || 0) + 1; }
	}
}

function terminalAppendError(data) {
	var item = data['console'] || {};
	if (item['uuid'] && $('#terminal_error_entries .terminal_entry[data-uuid="' + item['uuid'] + '"]').length) { return; }
	terminalAppendTo('terminal_error_entries', terminalEntryHtml('error', item, data['whoami'], data['hostname']), 'terminal_error_count');
}

function terminalAppendLog(data) {
	var item = data['console'] || {};
	if (item['uuid'] && $('#terminal_log_entries .terminal_entry[data-uuid="' + item['uuid'] + '"]').length) { return; }
	terminalAppendTo('terminal_log_entries', terminalEntryHtml('log', item, data['whoami'], data['hostname']), 'terminal_log_count');
}

function terminalAppendCommand(html) {
	terminalAppendTo('terminal_command_output', html);
}

function terminalClearView(view) {
	var setting = view === 'errors' ? 'errors' : 'log';
	var entries = document.getElementById(view === 'errors' ? 'terminal_error_entries' : 'terminal_log_entries');
	var badge = document.getElementById(view === 'errors' ? 'terminal_error_count' : 'terminal_log_count');
	settingSetter({ app: 'terminal', setting: setting, value: '[]' });
	if (entries) {
		var empty = entries.getAttribute('data-empty') || '';
		entries.innerHTML = '<div class="terminal_empty">' + terminalEscape(empty) + '</div>';
	}
	if (badge) { badge.textContent = '0'; }
}

/* ---- init ----------------------------------------------------------------- */

function terminalScreenEmpty() {
	var t = terminalVars;
	if (t.cursorX !== 0 || t.cursorY !== 0) { return false; }
	for (var y = 0; y < t.grid.length; y++) {
		var row = t.grid[y];
		if (!row) { continue; }
		for (var x = 0; x < row.length; x++) {
			if (row[x] && row[x].c && row[x].c !== ' ') { return false; }
		}
	}
	return t.history.length === 0;
}

function terminalInit() {
	var el = document.getElementById('terminal');
	if (!el) { return; }
	if (!terminalVars.decoder) {
		try { terminalVars.decoder = new TextDecoder('utf-8'); } catch (e) { terminalVars.decoder = null; }
	}
	var font = parseFloat(el.style.getPropertyValue('--terminal_font')) || 15;
	terminalVars.font = font;
	if (!terminalVars.initialized) {
		terminalVars.initialized = true;
		terminalVars.rows = 24;
		terminalVars.cols = 80;
		terminalReset(true);
	}
	if (!terminalVars.observer && typeof ResizeObserver !== 'undefined') {
		terminalVars.observer = new ResizeObserver(function () {
			window.clearTimeout(terminalVars.resizeTimer);
			terminalVars.resizeTimer = window.setTimeout(function () { terminalFit(false); }, 80);
		});
	}
	if (terminalVars.observer) {
		terminalVars.observer.disconnect();
		var wrap = document.getElementById('terminal_interactive');
		if (wrap) { terminalVars.observer.observe(wrap); }
	}
	var view = $('#terminal .terminal_view_select[selected]').attr('view') || 'interactive_terminal';
	terminalSetView(view, false);
	terminalStampTimes(document);
	terminalScrollListsBottom();
	setTimeout(function () { terminalFit(true); terminalRender(); }, 30);
	/* A fresh page missed the prompt written while no window was open. Ask the
	   shell to draw it again - but only on a blank screen: a session already on
	   screen is redrawn by its own activity, and a carriage return during a
	   password prompt would answer it. */
	if (terminalScreenEmpty()) { terminalSend({ type: 'terminal_refresh' }); }
}

/* ---- data from the server ------------------------------------------------- */

function terminalDataReceiver(rData) {
	var t = terminalVars;
	var base64String = rData['terminal'];
	if (!base64String) { return; }
	var binaryString = atob(base64String);
	var bytes = new Uint8Array(binaryString.length);
	for (var i = 0; i < binaryString.length; i++) { bytes[i] = binaryString.charCodeAt(i); }
	var text;
	if (t.decoder) { text = t.decoder.decode(bytes, { stream: true }); }
	else {
		text = '';
		for (var j = 0; j < bytes.length; j++) { text += String.fromCharCode(bytes[j]); }
	}
	terminalFeed(text);
}

/* ---- events --------------------------------------------------------------- */

$(document).on('click', '#terminal_interactive', function (e) {
	if ($(e.target).closest('button').length) { return; }
	terminalFocusKeyboard();
});

$(document).on('keydown', '#terminal_keyboard', function (e) {
	var data = terminalKeyData(e);
	if (data !== null) { terminalSendInput(data); }
});

$(document).on('input', '#terminal_keyboard', function () {
	var value = this.value;
	if (!value) { return; }
	this.value = '';
	terminalSendInput(value);
});

$(document).on('compositionstart', '#terminal_keyboard', function () {
	terminalVars.composing = true;
});

$(document).on('compositionend', '#terminal_keyboard', function (e) {
	terminalVars.composing = false;
	if (e.originalEvent && e.originalEvent.data) { terminalSendInput(e.originalEvent.data); }
});

$(document).on('paste', '#terminal_keyboard', function (e) {
	var oe = e.originalEvent;
	if (!oe || !oe.clipboardData) { return; }
	var text = oe.clipboardData.getData('text');
	if (!text) { return; }
	e.preventDefault();
	text = text.replace(/\r\n/g, '\r').replace(/\n/g, '\r');
	if (terminalVars.bracketedPaste) { text = '\x1b[200~' + text + '\x1b[201~'; }
	terminalSendInput(text);
});

$(document).on('focus', '#terminal_keyboard', function () {
	$('#terminal').removeClass('term_unfocused');
});

$(document).on('blur', '#terminal_keyboard', function () {
	$('#terminal').addClass('term_unfocused');
});

$(document).on('click', '#terminal_keyboard_toggle', function () {
	terminalSetView('interactive_terminal', true);
	terminalFocusKeyboard();
});

$(document).on('click', '#terminal_jump, #terminal_jump_bottom', function () {
	terminalScrollBottom();
	terminalFocusKeyboard();
});

$(document).on('wheel', '#terminal_interactive', function (e) {
	var oe = e.originalEvent || e;
	/* A full-screen app owns the screen; with no mouse reporting (we do not
	   enable it) the wheel is the arrow keys, as xterm sends them. */
	if (terminalVars.altActive) {
		terminalSendInput(oe.deltaY < 0 ? '\x1b[A' : '\x1b[B');
		e.preventDefault();
		return;
	}
	if (!terminalVars.history.length) { return; }
	if (oe.deltaY < 0) {
		terminalVars.scrollOffset = Math.min(terminalVars.history.length, terminalVars.scrollOffset + 3);
	}
	else {
		terminalVars.scrollOffset = Math.max(0, terminalVars.scrollOffset - 3);
	}
	terminalRender();
	e.preventDefault();
});

$(document).on('touchstart', '#terminal_interactive', function (e) {
	var oe = e.originalEvent || e;
	if (oe.touches && oe.touches.length === 1) { terminalVars.touchY = oe.touches[0].clientY; }
});

$(document).on('touchmove', '#terminal_interactive', function (e) {
	var oe = e.originalEvent || e;
	if (!oe.touches || oe.touches.length !== 1 || terminalVars.touchY === null) { return; }
	var dy = oe.touches[0].clientY - terminalVars.touchY;
	if (Math.abs(dy) < 6) { return; }
	terminalVars.scrollOffset = Math.max(0, Math.min(terminalVars.history.length, terminalVars.scrollOffset + (dy > 0 ? -1 : 1)));
	terminalVars.touchY = oe.touches[0].clientY;
	terminalRender();
	e.preventDefault();
});

$(document).on('click', '#terminal .terminal_view_select', function () {
	terminalSetView($(this).attr('view'), true);
});

$(document).on('click', '#terminal .terminal_clear', function () {
	terminalClearView($(this).attr('data-view'));
});

$(document).on('click', '#terminal_configure_toggle', function () {
	var panel = $('#terminal_configure');
	if (panel.is(':visible')) { panel.hide(); }
	else { panel.show(); }
});

$(document).on('click', '#terminal_configure .terminal_config_close', function () {
	$('#terminal_configure').hide();
});

$(document).on('click', '#terminal .terminal_shell_connect', function () {
	var host = $(this).attr('data-host') || '';
	var user = '';
	var port = '';
	if (host) {
		var row = $(this).closest('.terminal_remote_row');
		user = $.trim(row.find('.terminal_remote_user').val() || '');
		port = $.trim(row.find('.terminal_remote_port').val() || '');
	}
	$('#terminal_configure').hide();
	terminalShellConnect(host, user, port);
});

$(document).on('change', '#terminal_configure .terminal_remote_user, #terminal_configure .terminal_remote_port', function () {
	terminalSaveRemotes();
});

$(document).on('click', '#terminal .terminal_font_dec', function () {
	terminalSetFont(terminalVars.font - 1);
});

$(document).on('click', '#terminal .terminal_font_inc', function () {
	terminalSetFont(terminalVars.font + 1);
});

/* The command row is its own mode. It keeps a history of what was typed and
   sends the command to the same shell, then shows the shell so the output is
   visible. */
$(document).on('keydown', '#terminal_console', function (e) {
	if (e.key === 'Enter') {
		e.preventDefault();
		var command = $(this).val();
		$(this).val('');
		if (!command) { return; }
		terminalVars.commandHistory.push(command);
		terminalVars.commandIndex = terminalVars.commandHistory.length;
		var prompt = $('#terminal_console_prompt').text();
		terminalAppendCommand('<div class="terminal_entry terminal_entry_command">'
			+ '<div class="terminal_entry_head"><span class="terminal_entry_prompt">' + terminalEscape(prompt) + '</span></div>'
			+ '<div class="terminal_entry_msg">' + terminalEscape(command) + '</div></div>');
		terminalSendInput(command + '\r');
		terminalSetView('interactive_terminal', true);
	}
	else if (e.key === 'ArrowUp') {
		e.preventDefault();
		if (terminalVars.commandIndex > 0) {
			terminalVars.commandIndex--;
			$(this).val(terminalVars.commandHistory[terminalVars.commandIndex] || '');
		}
	}
	else if (e.key === 'ArrowDown') {
		e.preventDefault();
		if (terminalVars.commandIndex < terminalVars.commandHistory.length - 1) {
			terminalVars.commandIndex++;
			$(this).val(terminalVars.commandHistory[terminalVars.commandIndex] || '');
		}
		else {
			terminalVars.commandIndex = terminalVars.commandHistory.length;
			$(this).val('');
		}
	}
});

function terminalOpener(data) {
	data = data || {};
	var timestamp = Date.now();
	var oti = document.getElementById('terminal_interactive');
	var existing = $('.wind[app="terminal"]');
	if (existing.length) {
		existing.show();
		topLevelNow(existing.first());
		terminalInit();
		return;
	}
	$.ajax({
		url: '/manager/terminal',
		type: 'GET',
		data: { window_maker: data['window_maker'] || 'yes', timestamp: timestamp },
		success: function (response) {
			if ((data['window_maker'] || 'yes') === 'yes') {
				windowMaker(response);
			}
			else {
				$('#terminal').replaceWith(response);
			}
			terminalInit();
			var tv = $('#terminal_input');
			if (tv.length) { tv.show(); }
			if (!oti) {
				terminalFocusKeyboard();
			}
		}
	});
}
