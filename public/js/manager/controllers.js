// The Controller app, first slice: the roster, adding a controller and
// confirming its code. The page itself is drawn by GET /manager/controllers;
// the roster and the two pairing calls answer JSON. The posts go through
// $.ajax like the other apps' posts, so jQuery's X-Requested-With header
// satisfies the manager's CSRF check without a bespoke fetch wrapper.
$(document).on('click', '#controllers_toggle', function() {
	controllerOpener();
});

function controllerOpener() {
	$.ajax({
		url: '/manager/controllers',
		type: 'GET',
		data: { timestamp: Date.now() },
		success: function(response) {
			// The route may hand back the window itself or a { window: ... } /
			// { html: ... } envelope, depending on how it wrapped the page.
			var html = (response && (response.window || response.html)) || response;
			if (html) { windowMaker(html); }
			controllerRosterLoad();
		},
		error: function() {
			jawnosAlertText(controllerT('The Controller could not be opened.'));
		}
	});
}

// The house's translation helper, with a fallback so a page that loads before
// translate.js still shows its words.
function controllerT(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function controllerStatus(id, text, bad) {
	var el = $('#' + id);
	if (!el.length) { return; }
	el.text(text || '');
	el.toggleClass('controller_error', !!bad);
}

// ---- roster ----------------------------------------------------------------
function controllerRosterLoad() {
	var roster = $('#controller_roster');
	if (!roster.length) { return; }
	$.ajax({
		url: '/manager/controllers/list',
		type: 'GET',
		data: { timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			controllerRosterDraw((response && response.controllers) || []);
		},
		error: function() {
			roster.empty().append($('<div class="controller_empty"></div>')
				.text(controllerT('The controllers could not be read.')));
		}
	});
}

// A controller's last_seen is a moment when the server sends one and a word or
// nothing otherwise, so a number is read as epoch seconds or milliseconds and
// anything else is shown as it came.
function controllerSeenText(value) {
	if (value === undefined || value === null || value === '') { return controllerT('Never seen'); }
	var said = String(value);
	var n = Number(said);
	if (said.replace(/^\s+|\s+$/g, '') !== '' && !isNaN(n) && isFinite(n)) {
		var d = new Date(n < 1e12 ? n * 1000 : n);
		if (!isNaN(d.getTime())) { return d.toLocaleString(); }
	}
	return said;
}

function controllerRosterDraw(list) {
	var roster = $('#controller_roster');
	roster.empty();
	if (!list || !list.length) {
		roster.append($('<div class="controller_empty"></div>').text(controllerT('No controllers yet.')));
		return;
	}
	for (var i = 0; i < list.length; i++) {
		var c = list[i] || {};
		var row = $('<div class="controller_row"></div>');
		row.append($('<span class="controller_name"></span>').text(c.name || controllerT('Unnamed controller')));
		var where = [];
		if (c.hostname) { where.push(c.hostname); }
		if (c.ip && c.ip !== c.hostname) { where.push(c.ip); }
		row.append($('<span class="controller_where"></span>').text(where.join(' · ')));
		if (c.pending) {
			row.append($('<span class="controller_badge"></span>').text(controllerT('Pending')));
		}
		row.append($('<span class="controller_seen"></span>').text(controllerSeenText(c.last_seen)));
		roster.append(row);
	}
}

// ---- adding a controller ---------------------------------------------------
$(document).on('click', '#controller_add_button', function() {
	controllerRequest();
});

$(document).on('keydown', '#controller_name', function(e) {
	if (e.key == 'Enter') { e.preventDefault(); controllerRequest(); }
});

function controllerRequest() {
	var name = ($('#controller_name').val() || '').replace(/^\s+|\s+$/g, '');
	if (!name) {
		controllerStatus('controller_add_status', controllerT('Type the controller\'s name first.'), true);
		$('#controller_name').focus();
		return;
	}
	var button = $('#controller_add_button');
	button.prop('disabled', true);
	controllerStatus('controller_add_status', controllerT('Adding...'), false);
	$.ajax({
		url: '/manager/controllers/request',
		type: 'POST',
		data: { name: name, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				controllerStatus('controller_add_status', (response && response.error) || controllerT('The controller could not be added.'), true);
				return;
			}
			controllerStatus('controller_add_status', controllerT('Added. Confirm the code below.'), false);
			if (response.code) {
				$('#controller_code').text(response.code).prop('hidden', false);
				$('#controller_code_note').prop('hidden', false);
			}
			controllerRosterLoad();
		},
		error: function() {
			button.prop('disabled', false);
			controllerStatus('controller_add_status', controllerT('The controller could not be added.'), true);
		}
	});
}

// ---- approving a code ------------------------------------------------------
$(document).on('click', '#controllers_approve_button', function() {
	controllerApprove();
});

$(document).on('keydown', '#controllers_approve_code', function(e) {
	if (e.key == 'Enter') { e.preventDefault(); controllerApprove(); }
});

function controllerApprove() {
	var code = ($('#controllers_approve_code').val() || '').replace(/^\s+|\s+$/g, '');
	if (!code) {
		controllerStatus('controllers_approve_status', controllerT('Type the code first.'), true);
		$('#controllers_approve_code').focus();
		return;
	}
	var button = $('#controllers_approve_button');
	button.prop('disabled', true);
	controllerStatus('controllers_approve_status', controllerT('Approving...'), false);
	$.ajax({
		url: '/manager/controllers/approve',
		type: 'POST',
		data: { code: code, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				controllerStatus('controllers_approve_status', (response && response.error) || controllerT('The code was not approved.'), true);
				return;
			}
			$('#controllers_approve_code').val('');
			$('#controller_code').text('').prop('hidden', true);
			$('#controller_code_note').prop('hidden', true);
			controllerStatus('controllers_approve_status', controllerT('Approved.'), false);
			controllerRosterLoad();
		},
		error: function() {
			button.prop('disabled', false);
			controllerStatus('controllers_approve_status', controllerT('The code was not approved.'), true);
		}
	});
}
