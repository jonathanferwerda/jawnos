function terminalOpenSession(view) {
	var root = view.root;
	var payload = {
		app: 'server',
		type: 'terminal_open',
		terminal_id: view.id,
		host: root.getAttribute('data-session-host') || '',
		user: root.getAttribute('data-session-user') || '',
		port: root.getAttribute('data-session-port') || ''
	};
	var tries = 0;
	(function attempt() {
		if (typeof ws !== 'undefined' && ws['server'] && ws['server'].readyState === 1) {
			ws['server'].send(JSON.stringify(payload));
		}
		else if (++tries < 40) {
			setTimeout(attempt, 300);
		}
	})();
}

function terminalMarkOpenSessions(view) {
	if (!view || !view.root) { return; }
	var openIds = {};
	$.each(terminalViews, function (key, v) {
		if (v.root && v.root.isConnected) { openIds[v.id] = 1; }
	});
	$(view.root).find('.terminal_session_row').each(function () {
		var isOpen = !!openIds[$(this).attr('data-id')];
		$(this).toggleClass('already_open', isOpen);
		$(this).find('.terminal_session_open').prop('disabled', isOpen);
	});
}

function terminalMarkAllOpenSessions() {
	$.each(terminalViews, function (key, v) { terminalMarkOpenSessions(v); });
}

function terminalInitWindow(root) {
	if (!root) { return null; }
	if (root.__terminalView) { return root.__terminalView; }
	terminalPruneViews();
	var id = root.getAttribute('data-terminal-id') || terminalNewId();
	root.setAttribute('data-terminal-id', id);
	var state = terminalNewState();
	var view = { key: terminalNewViewKey(), id: id, root: root, state: state, observer: null, resizeTimer: null, opened: false };
	root.__terminalView = view;
	terminalViews[view.key] = view;
	terminalUse(view);
	try { state.decoder = new TextDecoder('utf-8'); } catch (e) { state.decoder = null; }
	state.font = parseFloat(root.style.getPropertyValue('--terminal_font')) || 15;
	state.rows = 24;
	state.cols = 80;
	terminalReset(true);
	if (typeof ResizeObserver !== 'undefined') {
		view.observer = new ResizeObserver(function () {
			window.clearTimeout(view.resizeTimer);
			view.resizeTimer = window.setTimeout(function () {
				if (!view.root.isConnected) { return; }
				terminalUse(view);
				terminalFit(false);
			}, 80);
		});
		var wrap = root.querySelector('.terminal_interactive');
		if (wrap) { view.observer.observe(wrap); }
	}
	var name = $(root).find('.terminal_view_select[selected]').attr('view') || 'interactive_terminal';
	terminalSetView(name, false);
	terminalStampTimes(root);
	terminalScrollListsBottom();
	setTimeout(function () {
		if (!view.root.isConnected) { return; }
		terminalUse(view);
		terminalFit(true);
		terminalRender();
	}, 30);
	terminalMarkAllOpenSessions();
	terminalOpenSession(view);
	return view;
}

function terminalInit() {
	var roots = document.querySelectorAll('.terminal_app');
	for (var i = 0; i < roots.length; i++) {
		if (!roots[i].__terminalView) { terminalInitWindow(roots[i]); }
	}
}

/* ---- data from the server ------------------------------------------------- */

function terminalPruneViews() {
	$.each(terminalViews, function (key, v) {
		if (!v.root || !v.root.isConnected) {
			if (v.observer) { v.observer.disconnect(); }
			delete terminalViews[key];
		}
	});
}

function terminalViewsForSession(id) {
	var found = [];
	$.each(terminalViews, function (key, v) {
		if (v.id === id && v.root && v.root.isConnected) { found.push(v); }
	});
	return found;
}

function terminalViewForMessage(id) {
	if (id) {
		var list = terminalViewsForSession(id);
		if (!list.length) { return null; }
		if (terminalCurrentView && terminalCurrentView.id === id && terminalCurrentView.root && terminalCurrentView.root.isConnected) {
			return terminalCurrentView;
		}
		return list[0];
	}
	if (terminalCurrentView && terminalCurrentView.root && terminalCurrentView.root.isConnected) { return terminalCurrentView; }
	var ids = Object.keys(terminalViews);
	for (var i = 0; i < ids.length; i++) {
		var candidate = terminalViews[ids[i]];
		if (candidate && candidate.root && candidate.root.isConnected) { return candidate; }
	}
	return null;
}

function terminalOpened(data) {
	if (!data) { return; }
	var views = terminalViewsForSession(data['terminal_id']);
	$.each(views, function (i, view) {
		terminalUse(view);
		view.opened = true;
		terminalSend({ type: 'terminal_resize', rows: view.state.rows, cols: view.state.cols });
		/* A window attached to a session that was already running has missed
		   whatever the shell drew. A carriage return asks it to draw the prompt
		   again; a brand-new session does not need it. */
		if (data['opened'] != 1 && terminalScreenEmpty()) {
			terminalSend({ type: 'terminal_refresh' });
		}
	});
}

function terminalDataReceiver(rData) {
	var base64String = rData['terminal'];
	if (!base64String) { return; }
	var text;
	if (rData['terminal_id']) {
		var target = terminalViewsForSession(rData['terminal_id']);
		if (!target.length) { return; }
		var binaryString = atob(base64String);
		var bytes = new Uint8Array(binaryString.length);
		for (var i = 0; i < binaryString.length; i++) { bytes[i] = binaryString.charCodeAt(i); }
		var decoder = target[0].state.decoder;
		if (decoder) { text = decoder.decode(bytes, { stream: true }); }
		else {
			text = '';
			for (var j = 0; j < bytes.length; j++) { text += String.fromCharCode(bytes[j]); }
		}
		$.each(target, function (i, view) {
			terminalUse(view);
			terminalFeed(text);
		});
		return;
	}
	var view = terminalViewForMessage();
	if (!view) { return; }
	terminalUse(view);
	var binaryString2 = atob(base64String);
	var bytes2 = new Uint8Array(binaryString2.length);
	for (var k = 0; k < binaryString2.length; k++) { bytes2[k] = binaryString2.charCodeAt(k); }
	if (view.state.decoder) { text = view.state.decoder.decode(bytes2, { stream: true }); }
	else {
		text = '';
		for (var m = 0; m < bytes2.length; m++) { text += String.fromCharCode(bytes2[m]); }
	}
	terminalFeed(text);
}

function terminalShellStatus(info) {
	if (!info) { return; }
	var views = terminalViewsForSession(info['terminal_id']);
	if (!views.length) {
		if (info['terminal_id']) { return; }
		var legacy = terminalViewForMessage();
		if (legacy) { views = [legacy]; }
	}
	$.each(views, function (i, view) {
		terminalUse(view);
		terminalApplyShellStatus(info);
	});
}

/* ---- events --------------------------------------------------------------- */

$(document).on('click', '.terminal_interactive', function (e) {
	if ($(e.target).closest('button').length) { return; }
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	terminalFocusKeyboard();
});

$(document).on('keydown', '.terminal_keyboard', function (e) {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	var data = terminalKeyData(e);
	if (data !== null) { terminalSendInput(data); }
});

$(document).on('input', '.terminal_keyboard', function () {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	var value = this.value;
	if (!value) { return; }
	this.value = '';
	terminalSendInput(value);
});

$(document).on('compositionstart', '.terminal_keyboard', function () {
	var view = terminalViewFrom(this);
	if (view) { view.state.composing = true; }
});

$(document).on('compositionend', '.terminal_keyboard', function (e) {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	view.state.composing = false;
	if (e.originalEvent && e.originalEvent.data) { terminalSendInput(e.originalEvent.data); }
});

$(document).on('paste', '.terminal_keyboard', function (e) {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	var oe = e.originalEvent;
	if (!oe || !oe.clipboardData) { return; }
	var text = oe.clipboardData.getData('text');
	if (!text) { return; }
	e.preventDefault();
	text = text.replace(/\r\n/g, '\r').replace(/\n/g, '\r');
	if (terminalVars.bracketedPaste) { text = '\x1b[200~' + text + '\x1b[201~'; }
	terminalSendInput(text);
});

$(document).on('focus', '.terminal_keyboard', function () {
	var view = terminalViewFrom(this);
	if (view) { $(view.root).removeClass('term_unfocused'); }
});

$(document).on('blur', '.terminal_keyboard', function () {
	var view = terminalViewFrom(this);
	if (view) { $(view.root).addClass('term_unfocused'); }
});

$(document).on('click', '.terminal_keyboard_toggle', function () {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	terminalSetView('interactive_terminal', true);
	terminalFocusKeyboard();
});

$(document).on('click', '.terminal_jump, .terminal_jump_bottom', function () {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	terminalScrollBottom();
	terminalFocusKeyboard();
});

$(document).on('wheel', '.terminal_interactive', function (e) {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
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

$(document).on('touchstart', '.terminal_interactive', function (e) {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	var oe = e.originalEvent || e;
	if (oe.touches && oe.touches.length === 1) { terminalVars.touchY = oe.touches[0].clientY; }
});

$(document).on('touchmove', '.terminal_interactive', function (e) {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	var oe = e.originalEvent || e;
	if (!oe.touches || oe.touches.length !== 1 || terminalVars.touchY === null) { return; }
	var dy = oe.touches[0].clientY - terminalVars.touchY;
	if (Math.abs(dy) < 6) { return; }
	terminalVars.scrollOffset = Math.max(0, Math.min(terminalVars.history.length, terminalVars.scrollOffset + (dy > 0 ? -1 : 1)));
	terminalVars.touchY = oe.touches[0].clientY;
	terminalRender();
	e.preventDefault();
});

$(document).on('click', '.terminal_view_select', function () {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	terminalSetView($(this).attr('view'), true);
});

$(document).on('click', '.terminal_clear', function () {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	terminalClearView($(this).attr('data-view'));
});

$(document).on('click', '.terminal_configure_toggle', function () {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	var panel = $(view.root).find('.terminal_configure');
	if (panel.is(':visible')) { panel.hide(); }
	else { terminalMarkOpenSessions(view); panel.show(); }
});

$(document).on('click', '.terminal_config_close', function () {
	var view = terminalViewFrom(this);
	if (view) { $(view.root).find('.terminal_configure').hide(); }
});

$(document).on('click', '.terminal_shell_connect', function () {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	var host = $(this).attr('data-host') || '';
	var user = '';
	var port = '';
	if (host) {
		var row = $(this).closest('.terminal_remote_row');
		user = $.trim(row.find('.terminal_remote_user').val() || '');
		port = $.trim(row.find('.terminal_remote_port').val() || '');
	}
	$(view.root).find('.terminal_configure').hide();
	terminalShellConnect(host, user, port);
});

$(document).on('change', '.terminal_remote_user, .terminal_remote_port', function () {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	terminalSaveRemotes();
});

$(document).on('click', '.terminal_session_end', function () {
	var row = $(this).closest('.terminal_session_row');
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	terminalSend({ type: 'terminal_end', terminal_id: row.attr('data-id') });
	row.remove();
});

$(document).on('click', '.terminal_session_open', function () {
	var row = $(this).closest('.terminal_session_row');
	var view = terminalViewFrom(this);
	if (view) { $(view.root).find('.terminal_configure').hide(); }
	terminalOpener({
		terminal_id: row.attr('data-id'),
		window_name: terminalWord('Terminal') + ' · ' + row.attr('data-label'),
		host: row.attr('data-host'),
		user: row.attr('data-user'),
		port: row.attr('data-port')
	});
});

$(document).on('click', '.terminal_font_dec', function () {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	terminalSetFont(terminalVars.font - 1);
});

$(document).on('click', '.terminal_font_inc', function () {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	terminalSetFont(terminalVars.font + 1);
});

/* The command row is its own mode. It keeps a history of what was typed and
   sends the command to the same shell, then shows the shell so the output is
   visible. */
$(document).on('keydown', '.terminal_console', function (e) {
	var view = terminalViewFrom(this);
	if (!view) { return; }
	terminalUse(view);
	if (e.key === 'Enter') {
		e.preventDefault();
		var command = $(this).val();
		$(this).val('');
		if (!command) { return; }
		terminalVars.commandHistory.push(command);
		terminalVars.commandIndex = terminalVars.commandHistory.length;
		var prompt = $(terminalEl('.terminal_console_prompt')).text();
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

/* Each call opens another terminal. Its id names the pty on the server, so a
   window closed (or minimised) and reopened keeps the same shell. */
function terminalOpener(data) {
	data = data || {};
	var id = data['terminal_id'] || terminalNewId();
	var name = data['window_name'] || terminalNextName();
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/terminal',
		type: 'GET',
		data: {
			window_maker: data['window_maker'] || 'yes',
			timestamp: timestamp,
			terminal_id: id,
			window_name: name,
			session_host: data['host'] || '',
			session_user: data['user'] || '',
			session_port: data['port'] || '',
			terminal_device: data['device'] || ''
		},
		success: function (response) {
			if ((data['window_maker'] || 'yes') === 'yes') {
				windowMaker(response);
			}
			else {
				$('#browser').append(response);
			}
			var win = $('.wind[data-terminal-id="' + id + '"]');
			var root = win.find('.terminal_app').get(0);
			var view = terminalInitWindow(root);
			if (win.length) {
				terminalMarkAllOpenSessions();
				/* New sessions cascade instead of landing exactly on the last one. */
				var siblings = $('.wind[app="terminal"]').length - 1;
				if (siblings > 0) {
					var left = (parseFloat(win.css('left')) || 0) + 28 * siblings;
					var top = (parseFloat(win.css('top')) || 0) + 28 * siblings;
					left = Math.max(4, Math.min(left, $(window).width() - win.outerWidth() - 8));
					top = Math.max(44, Math.min(top, $(window).height() - win.outerHeight() - 56));
					win.css({ left: left + 'px', top: top + 'px' });
				}
				if (view) { $(view.root).find('.terminal_keyboard').trigger('focus'); }
			}
		}
	});
}
