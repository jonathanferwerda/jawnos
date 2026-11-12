// The server-to-browser console channel. The server may send a command object
// { cmd, args } (Websocket::console_command). This router is the only place a
// command runs: a name from the table below, never an eval of a frame.
//
// Older sites still send a JS-shaped string. A string is accepted only when it
// is one of the static instructions in jawnosConsoleExact or matches the strict
// legacy parser below (a table name plus literal arguments). Anything else is
// refused and logged.
//
// terminalJs is the one deliberate exception: the terminal is a JS console the
// person is using on purpose, and Render.pm sends the line they typed alongside
// the literal marker 'terminal'. It is named here so an audit can find the two
// evals: that one, and browserCommand, which evals only a string the same strict
// validator accepts on the server.

var jawnosBrowserCommandClick = /^\$\((['"])([#.])([A-Za-z0-9_-]+)\1\)\.trigger\((['"])click\4\);?$/;
var jawnosBrowserCommandCurrent = /^tree\.sound\.currentTime = tree\.sound\.currentTime [+-] (?:\d+(?:\.\d+)?|\.\d+);?$/;
var jawnosBrowserCommandUnsafe = /(?:document|window|eval|Function|fetch|alert|[<>`])/;

// The JS twin of subs::browser_command_valid: trim, refuse a control character
// or a dangerous name, then accept only the two shapes the house uses.
function jawnosBrowserCommandValid(command) {
	if (typeof command !== 'string') { return false; }
	var s = command.replace(/^\s+|\s+$/g, '');
	if (!s.length || /[\x00-\x1f\x7f]/.test(s)) { return false; }
	if (jawnosBrowserCommandUnsafe.test(s)) { return false; }
	return jawnosBrowserCommandClick.test(s) || jawnosBrowserCommandCurrent.test(s);
}

var jawnosConsoleCommands = {
	appointmentDetailGrabber: function (a) {
		if (typeof appointmentDetailGrabber === 'function') { appointmentDetailGrabber(String(a[0]), String(a[1])); }
	},
	appointmentGrabber: function (a) {
		if (typeof appointmentGrabber === 'function') { appointmentGrabber(a[0], a[1], a[2] || 'ws'); }
	},
	appointmentGrabberIfVisible: function (a) {
		if (!document.hidden && typeof appointmentGrabber === 'function') { appointmentGrabber(a[0], a[1], a[2] || 'ws'); }
	},
	jpStop: function (a) {
		if (typeof jpStop === 'function') { jpStop(String(a[0]), String(a[1]), String(a[2])); }
	},
	jpScreen: function (a) {
		if (typeof jpScreen === 'function') { jpScreen(String(a[0]), String(a[1])); }
	},
	jpStart: function (a) {
		if (typeof jpStart === 'function') { jpStart(String(a[0]), String(a[1]), String(a[2])); }
	},
	configurationReloader: function (a) {
		if (typeof configurationReloader === 'function') { configurationReloader(a[0]); }
	},
	appWindowOpener: function (a) {
		if (typeof appWindowOpener === 'function') { appWindowOpener(a[0], a[1] || Date.now(), a[2] || {}); }
	},
	musicToggle: function (a) {
		if (typeof musicToggle === 'function') { musicToggle(a[0], a[1] ? 1 : 0); }
	},
	jawnosPrivateRefresh: function (a) {
		if (typeof jawnosPrivateRefresh === 'function') { jawnosPrivateRefresh(a[0] || 0); }
	},
	jawnosMediaLockdown: function (a) {
		if (typeof jawnosMediaLockdown === 'function') { jawnosMediaLockdown(a[0]); }
	},
	jawnosApptColourSet: function (a) {
		if (typeof jawnosApptColourSet === 'function') { jawnosApptColourSet(a[0], a[1], a[2]); }
	},
	jawnosApptDarkColourSet: function (a) {
		if (typeof jawnosApptDarkColourSet === 'function') { jawnosApptDarkColourSet(a[0], a[1]); }
	},
	jawnosReloadIcons: function () {
		if (typeof jawnosReloadIcons === 'function') { jawnosReloadIcons(); }
	},
	ticketList: function () {
		if (typeof ticket_list === 'function') { ticket_list(); }
	},
	tunnelLister: function () {
		if (typeof tunnelLister === 'function') { tunnelLister(); }
	},
	deviceLister: function () {
		if (typeof deviceLister === 'function') { deviceLister(); }
	},
	htopViewer: function () {
		if (typeof htopViewer === 'function') { htopViewer(); }
	},
	nowMeSuccess: function (a) {
		if (typeof nowMeSuccess === 'function') { nowMeSuccess(String(a[0]), String(a[1])); }
	},
	otaUploaderPercent: function (a) {
		$('#embedded_ota_uploader_percentage').text(String(a[0] || '') + ' ' + String(a[1] || '')).show();
	},
	registerGrabber: function (a) {
		if (typeof registerGrabber === 'function') { registerGrabber(String(a[0])); }
	},
	marketReload: function () {
		if (typeof marketReload === 'function') { marketReload(); }
	},
	calculator: function () {
		if (typeof calculator === 'function') { calculator(); }
	},
	notesReload: function () {
		if (typeof notesReload === 'function') { notesReload(); }
	},
	notesCategoriesReload: function () {
		if (typeof notesCategoriesReload === 'function') { notesCategoriesReload(); }
	},
	listProxy: function (a) {
		if (typeof listProxy === 'function') { listProxy(a[0], a[1]); }
	},
	setProxy: function (a) {
		if (typeof setProxy === 'function') { setProxy(a[0], a[1]); }
	},
	travelViewer: function (a) {
		if (typeof travelViewer === 'function') { travelViewer(a[0], a[1]); }
	},
	startMenuRefresh: function () {
		jawnosContinentAt = 0;
		if (typeof startMenuHtmlFlush === 'function') { startMenuHtmlFlush(); }
	},
	continentRecord: function (a) {
		if (typeof continent_record === 'function') { continent_record(a[0] || {}); }
	},
	marketPhoneScanStop: function () {
		if (typeof marketPhoneScanStop === 'function') { marketPhoneScanStop(); }
	},
	marketPhoneCamera: function (a) {
		if (typeof marketPhoneCamera === 'function') { marketPhoneCamera(a[0] || {}); }
	},
	marketScanArrived: function () {
		if (typeof marketScanArrived === 'function') { marketScanArrived(); }
	},
	jawnosThemeBundleApply: function (a) {
		if (typeof jawnosThemeBundleApply === 'function') { jawnosThemeBundleApply(a[0], a[1]); }
	},
	helpChatIngest: function (a) {
		if (typeof helpChatIngest === 'function') { helpChatIngest(String(a[0] || '')); }
	},
	jawnosClockAlarmRing: function (a) {
		if (typeof jawnosClockAlarmRing === 'function') { jawnosClockAlarmRing(a[0] || {}); }
	},
	jawnosSilence: function (a) {
		if (typeof jawnosSilenceApply === 'function') { jawnosSilenceApply(a[0] || {}); }
	},
	jawnosClockTimerDone: function (a) {
		if (typeof jawnosClockTimerDone === 'function') { jawnosClockTimerDone(a[0] || {}); }
	},
	jawnosClockRefresh: function (a) {
		if (typeof jawnosClockRefresh === 'function') { jawnosClockRefresh(a[0]); }
	},
	jawnosClockAlarmStop: function () {
		if (typeof jawnosClockAlarmStop === 'function') { jawnosClockAlarmStop(); }
	},
	musicVideoReceiverOpen: function (a) {
		if (typeof musicVideoReceiverOpen === 'function') { musicVideoReceiverOpen(String(a[0] || ''), a[1] || {}); }
	},
	musicVideoReceiverClose: function (a) {
		if (typeof musicVideoReceiverClose === 'function') { musicVideoReceiverClose(a[0]); }
	},
	boxOffice: function () {
		if ($('#box_office').is(':visible') && typeof boxOffice === 'function') { boxOffice(); }
	},
	fuckYou: function () {
		if (typeof fuck_you === 'function') { fuck_you(); }
	},
	reload: function () {
		location.reload();
	},
	setHtml: function (a) {
		var el = jawnosConsoleByAttr('.assistant_content', 'uuid', a[0]);
		if (el.length) { el.html(String(a[1])); }
	},
	setMeasure: function (a) {
		var m = jawnosConsoleByAttr('.appointment', 'app', a[0]).find('.app_measure')
			.filter(function () { return String($(this).attr('measure')) === String(a[1]); });
		if (m.length) { m.val(a[2]); }
	},
	setMeasureText: function (a) {
		var m = jawnosConsoleByAttr('.appointment', 'app', a[0]).find('.app_measure_display')
			.filter(function () { return String($(this).attr('measure')) === String(a[1]); });
		if (m.length) { m.text(a[2]); }
	},
	setToggle: function (a) {
		var t = jawnosConsoleByAttr('.appointment', 'app', a[0]).find('.enabler[type="toggle"]');
		if (!t.length) { return; }
		if (a[1] !== undefined) { t.attr('status', a[1]); }
		if (a[2]) { t.attr('src', a[2]); }
		if (a[3]) { t.attr('style', a[3]); }
	},
	setAppAct: function (a) {
		var el = jawnosConsoleByAttr('.app_act', 'app', a[0]).filter('[type="web"]');
		if (!el.length) { return; }
		if (a[1]) { el.attr('web', a[1]).show(); }
		else { el.attr('web', '').hide(); }
	},
	setMeasuresPv: function (a) {
		var el = jawnosConsoleByAttr('.measures_pv', 'app', a[0])
			.filter(function () { return String($(this).attr('measure')) === String(a[1]); });
		if (el.length) { el.text(a[2]); }
	},
	setEmailForm: function (a) {
		var w = jawnosConsoleByAttr('.wind', 'app', a[0]);
		if (w.length) { w.find('.email_compose_form').attr('uuid', a[1]); }
	},
	removeEmail: function (a) {
		jawnosConsoleByAttr('.email_message', 'uuid', a[0]).remove();
		jawnosConsoleByAttr('.mailbox_message', 'uuid', a[1] !== undefined ? a[1] : a[0]).remove();
	},
	removeMailbox: function (a) {
		jawnosConsoleByAttr('.mailbox_message', 'uuid', a[0]).remove();
	},
	removeAppointmentDetail: function (a) {
		jawnosConsoleByAttr('.appointment_detail', 'app', a[0])
			.filter(function () { return String($(this).attr('uuid')) === String(a[1]); }).remove();
	},
	closeButton: function (a) {
		var c = String(a[0] || '');
		if (/^[A-Za-z0-9_-]+$/.test(c)) { $('.' + c + '_close_button').trigger('click'); }
	},
	show: function (a) {
		var id = String(a[0] || '');
		if (/^[A-Za-z0-9_-]+$/.test(id)) { $('#' + id).show(); }
	},
	hide: function (a) {
		var id = String(a[0] || '');
		if (/^[A-Za-z0-9_-]+$/.test(id)) { $('#' + id).hide(); }
	},
	toggleLockdown: function (a) {
		// a command carries a real boolean or 1/0; the string '0' must not read as on
		var on = (a[0] === true || a[0] === 1 || a[0] === '1' || a[0] === 'true');
		$('#start_menu').toggleClass('lockdown', on);
	},
	setAppointmentAttr: function (a) {
		var name = String(a[1] || ''), value = String(a[2] === undefined ? '' : a[2]);
		// settings travel as attributes on the appointment card; never let one
		// install an event handler or a navigable URL
		if (!/^[a-z][a-z0-9_-]*$/.test(name) || /^on/.test(name)) { return; }
		if (name === 'style' || name === 'href' || name === 'src' || name === 'srcdoc' || name === 'formaction') { return; }
		jawnosConsoleByAttr('.appointment', 'app', a[0]).attr(name, value);
	},
	mediaUnlock: function (a) {
		var mode = String(a[0] || ''), token = String(a[1] || '');
		if (mode === 'gallery') {
			$('#gallery').attr('unlock', token);
			if (typeof imageViewer === 'function') { imageViewer({ view: 'home' }); }
		}
		else if (mode === 'music') {
			$('#music').attr('unlock', token);
			$('#music').show();
			$('#music_padlock').hide();
			if (typeof searchMusic === 'function') { searchMusic(); }
		}
		else if (mode === 'security') {
			if (typeof jawnosSecurityGrant === 'function') { jawnosSecurityGrant(token); }
		}
		else if (mode === 'private') {
			$('#security_private_padlock').hide();
			if (typeof jawnosPrivateRefresh === 'function') { jawnosPrivateRefresh(1); }
		}
		else if (mode === 'folders') {
			$('#folders').attr('unlock', token);
			if (typeof foldersOpener === 'function') { foldersOpener(); }
		}
	},
	padlockFrame: function () {
		$('#padlock_frame').html('');
		$('#padlock_frame').hide();
		$('#everything').show();
	},
	smsSend: function (a) {
		var d = String(a[0]), m = String(a[1]);
		if (typeof jawnSmsSend === 'function') { return jawnSmsSend(d, m); }
		if (window.JawnSms && window.JawnSms.send) { window.JawnSms.send(d, m); return 'bridge'; }
		$.post('/manager/sms/termux_fallback', { digits: d, message: m });
		return 'termux';
	},
	smsMms: function (a) {
		var d = String(a[0]), t = String(a[1]), p = a[2] || [], u = String(a[3] || '');
		var r = (typeof jawnSmsMms === 'function') ? jawnSmsMms(d, t, p, u) : 'no bridge';
		if (typeof window.__jawnSmsResult === 'function') {
			window.__jawnSmsResult({ ok: (r === 'ok' ? 1 : 0), via: 'mms_command', error: (r === 'ok' ? '' : r) });
		}
		return r;
	},
	terminalJs: function (a) {
		// The terminal is a JS console the person is using deliberately. Only
		// run_command's terminal path sends the marker, so a frame that carries
		// a line without it cannot reach this eval.
		if (String(a[1] || '') !== 'terminal') {
			console.warn('console: terminalJs without the terminal marker refused');
			return;
		}
		try { eval(String(a[0])); } catch (e) {}
	},
	browserCommand: function (a) {
		// A command saved in an app setting. The server already validated it;
		// the same check runs here so a hand-made frame cannot widen it.
		var command = String(a[0] == null ? '' : a[0]);
		if (!jawnosBrowserCommandValid(command)) {
			console.warn('console: browser command refused', command);
			return;
		}
		try { eval(command); } catch (e) {}
	}
};

// Static instructions that predate the structured protocol. They are constants,
// so an exact lookup is safe and cannot be widened by request data.
var jawnosConsoleExact = {
	'tunnelLister()': ['tunnelLister', []],
	'deviceLister()': ['deviceLister', []],
	'notesReload();': ['notesReload', []],
	'calculator();': ['calculator', []],
	'marketScanArrived();': ['marketScanArrived', []],
	'marketPhoneScanStop();': ['marketPhoneScanStop', []],
	'fuck_you();': ['fuckYou', []],
	'jawnosReloadIcons();': ['jawnosReloadIcons', []],
	'jawnosPrivateRefresh(0);': ['jawnosPrivateRefresh', [0]],
	'location.reload()': ['reload', []],
	'typeof ticket_list == "function" && ticket_list();': ['ticketList', []],
	'$("#box_office").is(":visible") && typeof boxOffice == "function" ? boxOffice() : 0;': ['boxOffice', []],
	'jawnosContinentAt = 0; if (typeof startMenuHtmlFlush == "function") { startMenuHtmlFlush(); }': ['startMenuRefresh', []],
	'$("#padlock_frame").html(""); $("#padlock_frame").hide();$("#everything").show();': ['padlockFrame', []],
	'$("#start_menu").toggleClass("lockdown", true);': ['toggleLockdown', [true]],
	'$("#start_menu").toggleClass("lockdown", false);': ['toggleLockdown', [false]],
	"$('#embedded_ota_uploader_wait').show()": ['show', ['embedded_ota_uploader_wait']],
	"$('#embedded_ota_uploader_wait').hide()": ['hide', ['embedded_ota_uploader_wait']],
	"$('#embedded_ota_uploader_success').show()": ['show', ['embedded_ota_uploader_success']],
	"$('#embedded_ota_uploader_success').hide()": ['hide', ['embedded_ota_uploader_success']],
	"$('#embedded_ota_uploader_fail').show()": ['show', ['embedded_ota_uploader_fail']],
	"$('#embedded_ota_uploader_fail').hide()": ['hide', ['embedded_ota_uploader_fail']]
};

function jawnosConsoleByAttr(selector, attr, value, scope) {
	var root = scope || $(document);
	return root.find(selector).filter(function () {
		return String($(this).attr(attr)) === String(value);
	});
}

function jawnosConsoleCall(cmd, args) {
	var fn = Object.prototype.hasOwnProperty.call(jawnosConsoleCommands, cmd) ? jawnosConsoleCommands[cmd] : null;
	if (typeof fn !== 'function') {
		console.warn('console: unknown command', cmd, args);
		return false;
	}
	try { fn(args || []); }
	catch (err) { console.error('console: ' + cmd, err); }
	return true;
}

// --- legacy instruction parser ---------------------------------------------
var jawnosConsoleBad = {};

function jawnosConsoleUnquote(tok) {
	tok = String(tok || '').trim();
	if (tok.length < 2) { return tok; }
	var q = tok.charAt(0);
	var body = tok.slice(1, -1);
	if (q === '"') {
		try { return JSON.parse(tok); }
		catch (e) { return body.replace(/\\"/g, '"').replace(/\\\\/g, '\\'); }
	}
	return body.replace(/\\'/g, "'").replace(/\\\\/g, '\\');
}

function jawnosConsoleSplitArgs(body) {
	var out = [], cur = '', depth = 0, quote = '';
	for (var i = 0; i < body.length; i++) {
		var ch = body.charAt(i);
		if (quote) {
			cur += ch;
			if (ch === '\\') { i++; if (i < body.length) { cur += body.charAt(i); } continue; }
			if (ch === quote) { quote = ''; }
			continue;
		}
		if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
		if (ch === '(' || ch === '[' || ch === '{') { depth++; cur += ch; continue; }
		if (ch === ')' || ch === ']' || ch === '}') { depth--; cur += ch; continue; }
		if (ch === ',' && depth === 0) { out.push(cur.trim()); cur = ''; continue; }
		cur += ch;
	}
	if (cur.trim().length || body.trim().length) { out.push(cur.trim()); }
	return out;
}

function jawnosConsoleAtom(tok) {
	tok = String(tok || '').trim();
	if (!tok.length) { return jawnosConsoleBad; }
	if (tok.charAt(0) === '"' || tok.charAt(0) === "'") { return jawnosConsoleUnquote(tok); }
	if (/^-?[0-9]+(?:\.[0-9]+)?$/.test(tok)) { return Number(tok); }
	if (tok === 'Date.now()') { return Date.now(); }
	if (tok === '{}') { return {}; }
	if (tok === 'true') { return true; }
	if (tok === 'false') { return false; }
	if (tok === 'null') { return null; }
	if (tok.charAt(0) === '[' || tok.charAt(0) === '{') {
		try { return JSON.parse(tok); } catch (e) { return jawnosConsoleBad; }
	}
	return jawnosConsoleBad;
}

function jawnosConsoleArgs(body) {
	var parts = jawnosConsoleSplitArgs(body);
	var out = [];
	for (var i = 0; i < parts.length; i++) {
		var v = jawnosConsoleAtom(parts[i]);
		if (v === jawnosConsoleBad) { return null; }
		out.push(v);
	}
	return out;
}

function jawnosConsoleFromCall(name, body) {
	if (!Object.prototype.hasOwnProperty.call(jawnosConsoleCommands, name)) { return false; }
	var args = jawnosConsoleArgs(body);
	if (args === null) { return false; }
	return jawnosConsoleCall(name, args);
}

function jawnosConsoleLegacyRun(s) {
	s = String(s || '').trim();
	var m;
	m = s.match(/^if \(!document\.hidden\) \{\s*([A-Za-z_][A-Za-z0-9_]*)\((.*)\);\s*\}$/);
	if (m) {
		var vis = jawnosConsoleArgs(m[2]);
		if (vis === null) { return false; }
		return jawnosConsoleCall(m[1] + 'IfVisible', vis);
	}
	m = s.match(/^continent_record\(\{\s*'uuid'\s*:\s*'([^']*)'\s*,\s*'app'\s*:\s*'([^']*)'\s*,\s*'purpose'\s*:\s*'([^']*)'\s*,\s*'timestamp'\s*:\s*'([^']*)'\s*,\s*'navigation'\s*:\s*"([^"]*)"\s*\}\);?$/);
	if (m) {
		return jawnosConsoleCall('continentRecord', [ { uuid: m[1], app: m[2], purpose: m[3], timestamp: m[4], navigation: m[5] } ]);
	}
	m = s.match(/^([A-Za-z_][A-Za-z0-9_]*)\((.*)\);?$/);
	if (m) { return jawnosConsoleFromCall(m[1], m[2]); }
	m = s.match(/^\$\((['"])\.assistant_content\[uuid=(?:"([^"]*)"|'([^']*)')\]\1\)\.html\((.*)\);?$/);
	if (m) { return jawnosConsoleCall('setHtml', [ m[2] || m[3], jawnosConsoleAtom(m[4]) ]); }
	m = s.match(/^\$\((['"])\.appointment\[app=(?:"([^"]*)"|'([^']*)')\]\1\)\.find\((['"])\.app_measure(_display)?\[measure=(?:"([^"]*)"|'([^']*)')\]\4\)\.(val|text)\((.*)\);?$/);
	if (m) {
		var mv = jawnosConsoleAtom(m[9]);
		return jawnosConsoleCall(m[5] ? 'setMeasureText' : 'setMeasure', [ m[2] || m[3], m[6] || m[7], mv ]);
	}
	m = s.match(/^\$\((['"])\.wind\[app=(?:"([^"]*)"|'([^']*)')\]\1\)\.find\((['"])\.email_compose_form\4\)\.attr\((['"])uuid\5,\s*(.*)\);?$/);
	if (m) { return jawnosConsoleCall('setEmailForm', [ m[2] || m[3], jawnosConsoleAtom(m[6]) ]); }
	m = s.match(/^\$\((['"])\.email_message\[uuid=(?:"([^"]*)"|'([^']*)')\]\1\)\.remove\(\);?\s*\$\((['"])\.mailbox_message\[uuid=(?:"([^"]*)"|'([^']*)')\]?\4\)\.remove\(\);?$/);
	if (m) { return jawnosConsoleCall('removeEmail', [ m[2] || m[3] ]); }
	m = s.match(/^\$\((['"])\.mailbox_message\[uuid=(?:"([^"]*)"|'([^']*)')\]?\1\)\.remove\(\);?$/);
	if (m) { return jawnosConsoleCall('removeMailbox', [ m[2] || m[3] ]); }
	m = s.match(/^\$\((['"])\.appointment_detail\[app=(?:"([^"]*)"|'([^']*)')\]\[uuid=(?:"([^"]*)"|'([^']*)')\]\1\)\.remove\(\);?$/);
	if (m) { return jawnosConsoleCall('removeAppointmentDetail', [ m[2] || m[3], m[4] || m[5] ]); }
	m = s.match(/^\$\((['"])\.measures_pv\[app=(?:"([^"]*)"|'([^']*)')\]\[measure=(?:"([^"]*)"|'([^']*)')\]\1\)\.text\((.*)\);?$/);
	if (m) { return jawnosConsoleCall('setMeasuresPv', [ m[2] || m[3], m[4] || m[5], jawnosConsoleAtom(m[6]) ]); }
	m = s.match(/^\$\((['"])\.app_act\[app=(?:"([^"]*)"|'([^']*)')\]\[type=(['"])web\4\]\1\)\.attr\((['"])web\5,\s*(.*?)\)\.(show|hide)\(\);?$/);
	if (m) {
		var wv = m[7] === 'hide' ? '' : jawnosConsoleAtom(m[6]);
		return jawnosConsoleCall('setAppAct', [ m[2] || m[3], wv ]);
	}
	m = s.match(/^\$\((['"])\.appointment\[app=(?:"([^"]*)"|'([^']*)')\]\1\)\.find\((['"])\.enabler\[type=(['"])toggle\5\]?\4\)\.attr\((['"])status\6,\s*(.*?)\)\.attr\((['"])src\8,\s*(.*?)\)(?:\.attr\((['"])style\10,\s*(.*?)\))?;?$/);
	if (m) {
		return jawnosConsoleCall('setToggle', [
			m[2] || m[3], jawnosConsoleAtom(m[7]), jawnosConsoleAtom(m[9]),
			m[11] === undefined ? undefined : jawnosConsoleAtom(m[11])
		]);
	}
	m = s.match(/^\$\((['"])\.([A-Za-z0-9_-]+)_close_button\1\)\.trigger\((['"])click\3\);?$/);
	if (m) { return jawnosConsoleCall('closeButton', [ m[2] ]); }
	return false;
}

function jawnosConsoleRun(payload) {
	if (!payload) { return false; }
	if (typeof payload === 'string') {
		var hit = jawnosConsoleExact[payload];
		if (hit) { return jawnosConsoleCall(hit[0], hit[1]); }
		return jawnosConsoleLegacyRun(payload);
	}
	if (typeof payload === 'object') {
		var args = Array.isArray(payload.args) ? payload.args : [];
		return jawnosConsoleCall(String(payload.cmd || ''), args);
	}
	return false;
}
