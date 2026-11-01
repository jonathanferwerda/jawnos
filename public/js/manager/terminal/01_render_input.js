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
	var view = terminalCurrentView;
	if (!view) { return; }
	if (view.state.raf) { return; }
	view.state.raf = window.requestAnimationFrame(function () {
		view.state.raf = null;
		terminalUse(view);
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
	var screen = terminalEl('.terminal_screen');
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
	var jump = terminalEl('.terminal_jump');
	if (jump) { jump.setAttribute('data-show', offset > 0 ? 'yes' : 'no'); }
}

/* ---- sizing --------------------------------------------------------------- */

function terminalMeasure() {
	var screen = terminalEl('.terminal_screen');
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
	var wrap = terminalEl('.terminal_interactive');
	if (!wrap || !$(wrap).is(':visible')) { return; }
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
	if (terminalCurrentView && !data['terminal_id']) { data['terminal_id'] = terminalCurrentView.id; }
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

function terminalScrollList(selector) {
	var el = terminalEl(selector);
	if (el) { el.scrollTop = el.scrollHeight; }
}

function terminalScrollListsBottom() {
	terminalScrollList('.terminal_error_entries');
	terminalScrollList('.terminal_log_entries');
	terminalScrollList('.terminal_command_output');
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

function terminalSetView(name, persist) {
	var cur = terminalCurrentView;
	if (!cur || !name) { return; }
	var root = cur.root;
	$(root).find('.terminal_view').css('display', 'none');
	$(root).find('.terminal_view[view="' + name + '"]').css('display', 'flex');
	$(root).find('.terminal_view_select').removeAttr('selected').attr('aria-selected', 'false');
	$(root).find('.terminal_view_select[view="' + name + '"]').attr('selected', 'selected').attr('aria-selected', 'true');
	if (persist) {
		settingSetter({ app: 'terminal', setting: 'view', value: name });
	}
	if (name === 'interactive_terminal') {
		terminalFit(true);
		terminalFocusKeyboard();
	}
	else if (name === 'terminal') {
		$(terminalEl('.terminal_console')).trigger('focus');
		terminalScrollList('.terminal_command_output');
	}
	else {
		terminalStampTimes(root);
		setTimeout(function () {
			if (cur === terminalCurrentView || cur.root.isConnected) {
				terminalUse(cur);
				terminalScrollList(name === 'errors' ? '.terminal_error_entries' : '.terminal_log_entries');
			}
		}, 0);
	}
}

function terminalFocusKeyboard() {
	var k = terminalEl('.terminal_keyboard');
	if (!k) { return; }
	try { k.focus({ preventScroll: true }); } catch (e) { k.focus(); }
}

function terminalApplyShellStatus(info) {
	if (!info) { return; }
	var cur = terminalCurrentView;
	if (!cur || !cur.root) { return; }
	var root = cur.root;
	var state = info['state'] || 'live';
	var label = info['label'] || '';
	var dot = terminalEl('.terminal_shell_dot');
	if (dot) {
		dot.className = 'terminal_dot ' + (state === 'connecting' ? 'connecting'
			: state === 'ended' ? 'ended'
			: state === 'local' ? 'local'
			: (info['local'] ? 'local' : 'remote'));
	}
	var suffix = state === 'connecting' ? ' · ' + terminalWord('connecting')
		: state === 'ended' ? ' · ' + terminalWord('ended') : '';
	$(terminalEl('.terminal_shell_status')).text(label + suffix).attr('title', (info['message'] || label));
	if (label) {
		root.setAttribute('data-shell-label', label);
	}
	$(root).find('.terminal_local_connect').removeClass('current');
	$(root).find('.terminal_remote_row').removeClass('current');
	if (state === 'local' || info['local']) {
		$(root).find('.terminal_local_connect').addClass('current');
	}
	else if (info['host']) {
		$(root).find('.terminal_remote_row[data-host="' + info['host'] + '"]').addClass('current');
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
	terminalApplyShellStatus({ state: host ? 'connecting' : 'local', label: label, local: !host });
	terminalSend(host
		? { type: 'terminal_connect', host: host, user: user, port: port }
		: { type: 'terminal_local' });
	terminalSetView('interactive_terminal', true);
	terminalFocusKeyboard();
}

function terminalSaveRemotes() {
	var root = terminalRoot();
	if (!root) { return; }
	var map = {};
	$(root).find('.terminal_remote_row').each(function () {
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
	var was = terminalCurrentView;
	$.each(terminalViews, function (id, v) {
		v.state.font = size;
		v.root.style.setProperty('--terminal_font', size + 'px');
		$(v.root).find('.terminal_font_size').text(size);
		terminalUse(v);
		terminalFit(true);
	});
	if (was && was.root && was.root.isConnected) { terminalUse(was); }
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

function terminalAppendTo(selector, badgeSelector, html) {
	var box = terminalEl(selector);
	if (!box) { return; }
	var atBottom = terminalNearBottom(box);
	var empty = box.querySelector('.terminal_empty');
	if (empty) { empty.parentNode.removeChild(empty); }
	box.insertAdjacentHTML('beforeend', html);
	if (box.lastElementChild) { terminalStampTimes(box.lastElementChild); }
	if (atBottom) { box.scrollTop = box.scrollHeight; }
	if (badgeSelector) {
		var badge = terminalEl(badgeSelector);
		if (badge) { badge.textContent = (parseInt(badge.textContent, 10) || 0) + 1; }
	}
}

function terminalAppendErrorFor(data) {
	var item = data['console'] || {};
	if (item['uuid'] && $(terminalEl('.terminal_error_entries')).find('.terminal_entry[data-uuid="' + item['uuid'] + '"]').length) { return; }
	terminalAppendTo('.terminal_error_entries', '.terminal_error_count', terminalEntryHtml('error', item, data['whoami'], data['hostname']));
}

function terminalAppendLogFor(data) {
	var item = data['console'] || {};
	if (item['uuid'] && $(terminalEl('.terminal_log_entries')).find('.terminal_entry[data-uuid="' + item['uuid'] + '"]').length) { return; }
	terminalAppendTo('.terminal_log_entries', '.terminal_log_count', terminalEntryHtml('log', item, data['whoami'], data['hostname']));
}

function terminalAppendError(data) {
	$.each(terminalViews, function (id, v) {
		if (!v.root.isConnected) { return; }
		terminalUse(v);
		terminalAppendErrorFor(data);
	});
}

function terminalAppendLog(data) {
	$.each(terminalViews, function (id, v) {
		if (!v.root.isConnected) { return; }
		terminalUse(v);
		terminalAppendLogFor(data);
	});
}

function terminalAppendCommand(html) {
	terminalAppendTo('.terminal_command_output', null, html);
}

function terminalClearView(kind) {
	var setting = kind === 'errors' ? 'errors' : 'log';
	var selector = kind === 'errors' ? '.terminal_error_entries' : '.terminal_log_entries';
	var badgeSelector = kind === 'errors' ? '.terminal_error_count' : '.terminal_log_count';
	settingSetter({ app: 'terminal', setting: setting, value: '[]' });
	$.each(terminalViews, function (id, v) {
		terminalUse(v);
		var entries = terminalEl(selector);
		var badge = terminalEl(badgeSelector);
		if (entries) {
			var empty = entries.getAttribute('data-empty') || '';
			entries.innerHTML = '<div class="terminal_empty">' + terminalEscape(empty) + '</div>';
		}
		if (badge) { badge.textContent = '0'; }
	});
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

