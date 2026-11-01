$(document).on('click', '#lock_session', function() {
	if (lockSessionTap) {
		clearTimeout(lockSessionTap);
		lockSessionTap = null;
		// double tap: lock the whole house
		jawnLockScreen('all');
		return;
	}
	lockSessionTap = setTimeout(function() {
		lockSessionTap = null;
		// single tap: lock this screen
		jawnLockScreen('');
	}, 300);
});

$(document).on('click', '.enabler', function() {
	var strawbeery = $(this);
	var appointment = strawbeery.closest('.appointment');
	var app = appointment.attr('app');
	var timestamp = Date.now();
	var setting = strawbeery.attr('type') || 'notification';
	var status = strawbeery.attr('status');
	var on_colour = strawbeery.attr('on_colour');
	var off_colour = strawbeery.attr('off_colour');
	var dim = strawbeery.attr('dim');
	if (status == 'on') {
		strawbeery.css({ 'background-color': off_colour });
		if (dim) { strawbeery.css({ 'border-color': off_colour, 'opacity': '0.45', 'filter': 'grayscale(1)', 'box-shadow': 'none' }); }
		status = 'off';
	}
	else {
		strawbeery.css({ 'background-color': on_colour });
		if (dim) { strawbeery.css({ 'border-color': on_colour, 'opacity': '1', 'filter': 'none', 'box-shadow': '0 0 8px 2px ' + on_colour }); }
		status = 'on';
	}

	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: app, timestamp: timestamp, setting: setting, value: status, source: 'panel' },
		success: function(response) {
			centreViewWriter(response)
		}
	});
});

// A machine's own Manager, in a window of its own, at that machine's origin.
// It is deliberately not framed inside this page: the peer's localStorage and
// cookies then belong to the peer's origin alone (and a framed peer would be
// refused by the app gate, which admits installed apps, not nested browsers).
// The desktop app opens a real window at the peer and lets its app-required
// page sign in with this install's key; a plain browser gets a new tab.
function jawnosDesktopCall(action, args) {
	return new Promise(function (resolve, reject) {
		if (!window.JawnDesktop || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.jawnos) {
			reject({ error: 'unavailable' }); return;
		}
		var id = 'app' + Date.now() + Math.random().toString(36).slice(2);
		var done = false;
		// an older desktop app ignores the action and never replies; do not hang
		var timer = setTimeout(function () {
			if (done) { return; }
			done = true;
			window.__jawnAppResult = null;
			reject({ error: 'timeout' });
		}, 2500);
		window.__jawnAppResult = function (rid, res) {
			if (rid !== id || done) { return; }
			done = true;
			clearTimeout(timer);
			window.__jawnAppResult = null;
			if (res && res.ok) { resolve(res); } else { reject(res || { error: 'failed' }); }
		};
		try {
			window.webkit.messageHandlers.jawnos.postMessage(JSON.stringify({ action: action, id: id, args: args || {} }));
		}
		catch (e) {
			window.__jawnAppResult = null;
			reject({ error: 'unavailable' });
		}
	});
}

// A peer ticket can arrive as a path. Resolve it against the peer's own
// manager, never against this page's origin: the local origin would open this
// house's manager (the local Gate) instead of the peer's.
function jawnosRemoteUrl(url, manager) {
	if (!url) { return ''; }
	if (/^https?:\/\//i.test(url)) { return url; }
	if (manager && /^https?:\/\//i.test(manager)) {
		try { return new URL(url, manager).href; } catch (e) {}
	}
	return url;
}

function jawnosRemoteHint(text) {
	var b = $('#remote_control_go');
	if (b.length) { b.attr('hint', text); }
	if (typeof jawnosUpdateNote === 'function') { jawnosUpdateNote(text); }
}

function jawnosRemoteManagerWindow(url, uuid, name, device, manager) {
	if (!url) { return; }
	url = jawnosRemoteUrl(url, manager);
	var device_uuid = device || '';
	if (!device_uuid) {
		try { device_uuid = localStorage.getItem('device_uuid') || ''; } catch (e) { device_uuid = ''; }
	}
	if (!window.JawnDesktop) {
		jawnosRemoteHint((typeof jawnosT === 'function') ? jawnosT('Open this in the JawnOS app') : 'Open this in the JawnOS app');
		return;
	}
	jawnosDesktopCall('open_manager', { url: url, manager: manager || url, device_uuid: device_uuid, name: name || '' }).catch(function (err) {
		// The desktop app owns this window. Never fall back to window.open:
		// WebKit hands that to the default browser, which produced a second
		// tab (often the local Gate) beside the JawnOS window.
		jawnosRemoteHint((typeof jawnosT === 'function') ? jawnosT('The JawnOS window could not be opened') : 'The JawnOS window could not be opened');
	});
}

function jawnosRemoteManagerOpen(uuid, manager) {
	if (!uuid && !manager) { return; }
	var data = {
		timestamp: Date.now(),
		// The desktop bridge is what opens a real JawnOS window; when it is
		// missing the page can only explain that the app is required.
		desktop: window.JawnDesktop ? 1 : 0,
		bridge: (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.jawnos) ? 1 : 0
	};
	if (uuid) { data.uuid = uuid; }
	else { data.manager = manager; }
	$.ajax({
		url: '/manager/remote_manager',
		type: 'GET',
		data: data,
		dataType: 'json',
		success: function (r) {
			if (!r) { return; }
			if (r.need_approval) {
				jawnosGoPrompt(r, uuid, manager);
				return;
			}
			// In the app a ticket is what signs the peer window in. When the
			// mint failed (a peer restarting) opening the bare manager would
			// only show that machine's Gate; say so and let the person retry.
			if (r.ticket_failed) {
				jawnosRemoteHint((typeof jawnosT === 'function') ? jawnosT('That machine is not ready to sign you in. Try again in a moment.') : 'That machine is not ready to sign you in. Try again in a moment.');
				return;
			}
			if (r.manager) {
				var target = jawnosRemoteUrl(r.ticket_url || r.manager, r.manager || manager);
				jawnosRemoteManagerWindow(target, r.uuid || uuid, r.name, r.device_uuid, r.manager);
			}
		},
		fail: function (xhr) {
			// The app gate answers a session that has not signed the installed
			// app with the app-required page. The app can sign itself in and
			// retry; a browser has no key, so it still gets the plain window.
			if (xhr && xhr.responseText && xhr.responseText.indexOf('JawnOS app required') >= 0
				&& typeof jawnAppLogin === 'function') {
				jawnAppLogin(true).then(function () {
					jawnosRemoteManagerOpen(uuid, manager);
				}, function () {
					if (manager) { jawnosRemoteManagerWindow(manager, uuid); }
				});
				return;
			}
			// An old stored Go link can name a machine the roster no longer
			// matches. Open that address when it is a real host; never open this
			// machine's own manager (the tunnel loopback) as if it were a peer.
			if (manager && !/^https?:\/\/(?:127\.0\.0\.1|localhost|\[::1\])(?::|\/|$)/i.test(manager)) {
				jawnosRemoteManagerWindow(jawnosRemoteUrl(manager, manager), uuid);
			}
			else {
				jawnosRemoteHint((typeof jawnosT === 'function') ? jawnosT('That machine has no reachable address') : 'That machine has no reachable address');
			}
		}
	});
}

// A Go from the installed app asks for a second factor before the peer ticket
// is minted. The server names what this house can provide: this computer's
// reader, the phone's own Keystore print, or another paired device's print.
// The request is short-lived and bound to this session; the approved poll mints
// the ticket and opens the peer exactly as the direct path did.
function jawnosGoPrompt(r, uuid, manager) {
	var t = function (s, v) { return (typeof jawnosT === 'function') ? jawnosT(s, v) : s; };
	var done = false;
	var timer = null;
	var fingerBtn = null;
	var phoneBtn = null;
	var askBtn = null;
	var noBtn = null;
	var box = $('<div>').attr('id', 'jawnos_go_prompt').attr('role', 'dialog').attr('aria-modal', 'true').css({
		position: 'fixed', zIndex: 2147483000, left: '50%', top: '50%', transform: 'translate(-50%,-50%)',
		width: 'min(92vw,380px)', background: '#161616', color: '#f4f4f4', border: '1px solid #444',
		borderRadius: '14px', padding: '18px', boxShadow: '0 12px 40px rgba(0,0,0,.55)',
		fontFamily: 'sans-serif', textAlign: 'center'
	});
	var title = $('<div>').css({ fontSize: '19px', lineHeight: '1.35', marginBottom: '6px' }).text(t('Open {0}?', r.name || t('the machine')));
	var note = $('<div>').css({ fontSize: '14px', color: '#bbb', marginBottom: '14px', minHeight: '18px' }).text(t('Confirm it is you before this window opens.'));
	var row = $('<div>');
	var btnCss = 'font-size:14px;padding:9px 14px;border-radius:9px;border:1px solid #555;background:#222;color:#f4f4f4;cursor:pointer;margin:0 4px 8px 4px;';
	function addButton(text, css, handler) {
		var b = $('<button type="button">').text(text).css(css).on('click', handler);
		row.append(b);
		return b;
	}
	function enable(on) {
		$(row).find('button').prop('disabled', !on);
	}
	function disable(keep) {
		var keepers = keep || [];
		$(row).find('button').each(function () {
			if (this === noBtn || keepers.indexOf(this) >= 0) { return; }
			$(this).prop('disabled', true);
		});
	}
	if (r.fingerprint) {
		fingerBtn = addButton(t("Use this computer's fingerprint"), btnCss + 'border-color:#2b6;background:#2b6;color:#08110a;font-weight:bold;', function () { startFingerprint(); });
	}
	if (r.phone_fingerprint && window.JawnBiometricKey && typeof jawnosBiometricGo === 'function') {
		phoneBtn = addButton(t("Use this phone's fingerprint"), btnCss + 'border-color:#2b6;background:#2b6;color:#08110a;font-weight:bold;', function () { startPhone(); });
	}
	if (r.devices && r.devices.length) {
		askBtn = addButton(t('Ask another device'), btnCss, function () { startAsk(); });
	}
	noBtn = addButton(t('Not now'), btnCss, function () { close(); });
	box.append(title).append(note).append(row);
	$('body').append(box);

	function close() {
		done = true;
		if (timer) { clearInterval(timer); timer = null; }
		box.remove();
	}
	function wait(text) { note.text(text); }
	function open(res) {
		close();
		var url = (res && res.ticket_url) || r.manager;
		if (!url) { return; }
		jawnosRemoteManagerWindow(url, (res && res.uuid) || r.uuid || uuid, (res && res.name) || r.name,
			(res && res.device_uuid) || r.device_uuid, (res && res.manager) || manager || r.manager);
	}
	function failed() {
		if (done) { return; }
		wait(t('That did not work. Try again.'));
		enable(true);
	}
	function poll() {
		if (done) { return; }
		$.ajax({ url: '/manager/security/go_status', type: 'GET', data: { request_id: r.request_id, timestamp: Date.now() }, dataType: 'json', cache: false })
			.done(function (res) {
				if (done) { return; }
				if (res && res.approved && res.ticket_url) { open(res); return; }
				if (!res || !res.ok) {
					wait(t('That did not work. Try again.'));
					close();
				}
			})
			.fail(function () { failed(); });
	}
	function startFingerprint() {
		disable([askBtn]);
		wait(t('Touch the fingerprint reader now...'));
		$.ajax({ url: '/manager/security/fingerprint_unlock', type: 'POST', data: { purpose: 'go', request_id: r.request_id, timestamp: Date.now() }, dataType: 'json', cache: false })
			.done(function (res) {
				if (res && res.pending && res.token) { pollPrint(res.token, 0); return; }
				failed();
			})
			.fail(function () { failed(); });
	}
	function pollPrint(token, tries) {
		$.ajax({ url: '/manager/security/fingerprint_unlock_status', type: 'GET', data: { token: token, timestamp: Date.now() }, dataType: 'json', cache: false })
			.done(function (res) {
				if (done) { return; }
				if (res && res.pending) {
					if (tries > 30) { wait(t('The reader timed out.')); enable(true); return; }
					setTimeout(function () { pollPrint(token, tries + 1); }, 700);
					return;
				}
				if (res && res.ok) { wait(t('Approved. Opening...')); poll(); return; }
				failed();
			})
			.fail(function () { failed(); });
	}
	function startPhone() {
		disable([askBtn]);
		wait(t('Confirm your fingerprint...'));
		jawnosBiometricGo(r.request_id, r.name, function (s) { wait(s); }).then(function () {
			wait(t('Approved. Opening...'));
			poll();
		}).catch(function (err) {
			if (done) { return; }
			wait((typeof jawnosBiometricError === 'function') ? jawnosBiometricError(err) : t('That did not work. Try again.'));
			enable(true);
		});
	}
	function startAsk() {
		disable([fingerBtn, phoneBtn]);
		wait(t('Waiting for another device...'));
		$.ajax({ url: '/manager/security/go_ask', type: 'POST', data: { request_id: r.request_id, timestamp: Date.now() }, dataType: 'json', cache: false })
			.done(function (res) {
				if (res && res.ok) { wait(t('Waiting for another device...')); return; }
				failed();
			})
			.fail(function () { failed(); });
	}
	// The preferred factor asks first (the laptop's reader, or the phone's own
	// Keystore print); another device stays one tap away, and Not now is always
	// live. A desktop with no reader falls through to asking the house.
	timer = setInterval(poll, 1200);
	if (r.fingerprint) {
		startFingerprint();
	}
	else if (r.phone_fingerprint && window.JawnBiometricKey && typeof jawnosBiometricGo === 'function') {
		startPhone();
	}
	else {
		poll();
	}
}

$(document).on('click', '.remote_manager_open', function (e) {
	// a new tab is still a legitimate way to open it
	if (e.ctrlKey || e.metaKey || e.shiftKey || e.which === 2) { return; }
	e.preventDefault();
	var b = $(this);
	jawnosRemoteManagerOpen(b.attr('uuid'), b.attr('manager'));
});

// Go links filed in remote_machines.buttons before the button existed still
// open the machine's window rather than a tab.
$(document).on('click', '.remote_machine_buttons a[target="_blank"]', function (e) {
	if (e.ctrlKey || e.metaKey || e.shiftKey || e.which === 2) { return; }
	var href = $(this).attr('href') || '';
	if (href.indexOf('/manager') < 0) { return; }
	e.preventDefault();
	jawnosRemoteManagerOpen('', href);
});

function cacheSet(params,data) {
	var jdata = JSON.stringify(data);
	$.ajax({
		url: '/manager/cache_set',
		type: 'POST',
		data: {
			app: params['app'],
			context: params['context'],
			subcontext: params['subcontext'],
			timestamp: params['timestamp'],
			data: jdata
		},
		success: function(response) {}
	});
}

async function cacheGet(params) {

	return $.ajax({
		url: '/manager/cache_get',
		type: 'GET',
		data: {
			app: params['app'],
			context: params['context'],
			subcontext: params['subcontext'],
			timestamp: params['timestamp'],
		},
		success: function(response) {
		}
	});
}

function cacheDelete(params) {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/cache_delete',
		type: 'POST',
		data: {
			app: params['app'],
			context: params['context'],
			subcontext: params['subcontext'],
			timestamp: timestamp,
		},
		success: function(response) {}
	});
}
