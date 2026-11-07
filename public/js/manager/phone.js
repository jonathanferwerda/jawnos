// The Phone app. Recents are the appointments whose subtype is 'phone';
// contacts are the house's known phone numbers; the dial pad places a call on a
// phone through /manager/phone/dial (termux-telephony-call). In the app it also
// reads the device's own contacts and live call state from window.JawnContacts,
// and writes a call appointment as the call happens.
var jawnPhoneApp = { number: '' };

// The screening face's Connect me opens this page with ?connect=me. The page is
// the WebRTC peer, so all that is left here is to press the button once the
// gateway says a call is up. The query is stripped straight away: a reload must
// not silently connect a device again.
var jawnPhoneConnectMeWanted = /[?&]connect=me(?:&|$)/.test(window.location.search || '');
if (jawnPhoneConnectMeWanted) {
	try { window.history.replaceState({}, '', window.location.pathname); } catch (e) { }
}

function jawnPhoneAppStatus(text) {
	$('#phone_app #phone_app_status').text(text || 'Idle');
}

// A millisecond count (the stored duration may be negative) to "3m 12s".
function jawnPhoneAppHuman(ms) {
	ms = Math.abs(Number(ms || 0));
	if (!ms) return '';
	var s = Math.floor(ms / 1000);
	var m = Math.floor(s / 60); s %= 60;
	var h = Math.floor(m / 60); m %= 60;
	if (h) return h + 'h ' + m + 'm';
	if (m) return m + 'm ' + s + 's';
	return s + 's';
}

// Fill in each recent row's duration beside its clock time.
function jawnPhoneAppRender() {
	$('#phone_app .phone_app_row[app]').each(function () {
		var sub = $(this).find('.phone_app_sub');
		var d = sub.attr('duration');
		if (d) {
			var dur = jawnPhoneAppHuman(d);
			if (dur) sub.text(sub.text() + ' · ' + dur);
		}
	});
}

// ---- live calls -----------------------------------------------------------
// The appointment itself is written from the app's own record of the call (see
// jawnPhoneAppFileCalls below): a call arrives whether or not a page is up, and
// the native side is the only half that sees every one of them. That is what
// this listener used to get wrong - it wrote the appointment itself, so a call
// taken with the app in the background was written nowhere. All it does now is
// say what is happening on screen.
// 'prev' holds the bridge's own vocabulary (IDLE/RINGING/OFFHOOK): the native
// side spells the states in capitals, so comparing against a lowercase 'idle'
// never matched.
var jawnPhoneAppCall = { prev: 'IDLE' };

function jawnPhoneAppNumber() {
	try {
		if (window.JawnContacts && typeof window.JawnContacts.incomingNumber === 'function') {
			return window.JawnContacts.incomingNumber() || '';
		}
	} catch (e) { }
	return '';
}

function jawnPhoneAppOnState(state) {
	state = (state || '').toUpperCase();
	if (state === 'RINGING') { jawnPhoneAppStatus('Incoming call…'); }
	else if (state === 'OFFHOOK') { jawnPhoneAppStatus('On a call'); }
	else { jawnPhoneAppStatus('Idle'); }
	jawnPhoneAppCall.prev = state;
}

// The calls the app recorded (window.JawnPhone.takeCalls) become appointments,
// one each. Run at page load, on every jawnPhoneSync, and the moment the native
// side says a call has finished - so a call that happened while the app was in
// the background lands as soon as there is a page to file it.
function jawnPhoneAppFileCalls(reload) {
	if (!window.JawnPhone || typeof window.JawnPhone.takeCalls !== 'function') { return; }
	var calls = [];
	try { calls = JSON.parse(window.JawnPhone.takeCalls()) || []; } catch (e) { calls = []; }
	if (!calls.length) { return; }
	var filed = 0;
	$.each(calls, function (i, c) {
		if (!c) { return; }
		$.ajax({
			url: '/manager/phone/call',
			type: 'POST',
			data: {
				timestamp: c.ended || Date.now(),
				event: 'log',
				number: c.number || '',
				direction: c.direction || 'incoming',
				started: c.started || 0,
				ended: c.ended || 0,
				answered: c.answered ? 'yes' : 'no'
			},
			success: function (res) {
				filed++;
				if (filed === calls.length && reload && $('#phone_app').length) { jawnPhoneAppReload('recent'); }
			}
		});
	});
}

// the native side nudges us here when a call ends (JawnInCallService)
window.__jawnPhoneCalls = function () { jawnPhoneAppFileCalls(true); };

// The native bridge pushes call state here (window.JawnContacts -> the app).
window.__jawnPhoneEvent = function (type, payload) {
	if (type !== 'state') return;
	jawnPhoneAppOnState(payload && payload.state);
};

// Pull the whole app again and land on a pane: after a block or an unblock the
// panes a number touches have all changed, and a reload of the window is what
// keeps every one of them honest.
function jawnPhoneAppReload(pane) {
	$.ajax({
		url: '/manager/phone',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) {
			windowMaker(response);
			jawnPhoneAppRender();
			jawnPhoneAppArm();
			if (pane) { $('#phone_app .phone_app_tab[pane="' + pane + '"]').trigger('click'); }
		}
	});
}

$(document).on('click', '#phone_toggle', function () {
	jawnPhoneAppReload();
});

// tab switching
$(document).on('click', '#phone_app .phone_app_tab', function () {
	$('#phone_app .phone_app_tab').removeClass('on');
	$(this).addClass('on');
	var pane = $(this).attr('pane');
	$('#phone_app .phone_app_pane').removeClass('on');
	$('#phone_app .phone_app_pane[pane="' + pane + '"]').addClass('on');
});

// The phone icon on a recent opens the device's default dialer with the number
// already typed. The native JawnPhone bridge is the only half that can do that;
// on the desktop the house's own dial pad is the fallback.
$(document).on('click', '#phone_app .phone_app_row_call', function (e) {
	e.stopPropagation();
	var row = $(this).closest('.phone_app_row');
	var number = $(this).attr('number') || row.attr('number') || '';
	if (!number) { jawnPhoneAppStatus(jawnosT('No number to dial.')); return; }
	if (window.JawnPhone && typeof window.JawnPhone.dial === 'function') {
		window.JawnPhone.dial(number);
		jawnPhoneAppStatus(jawnosT('Opening dialer…'));
		return;
	}
	jawnPhoneApp.number = number;
	$('#phone_app #phone_app_display').text(number);
	$('#phone_app .phone_app_tab[pane="dial"]').trigger('click');
});

// The IVR pane's save: the settings are the phone's own setting rows, and the
// machine is the remote_machines signatorial (or IP) the gateway runs on. The
// named flows ride in one JSON string; the older top-level prompt fields follow
// the receptionist flow, so a machine speaking from those rows agrees.
$(document).on('click', '#phone_app #phone_ivr_save', function (e) {
	e.preventDefault();
	var status = $('#phone_app #phone_ivr_status');
	status.text(jawnosT('Saving…'));
	var flows = {};
	$('#phone_app .phone_app_ivr_flow').each(function() {
		flows[$(this).attr('bucket')] = $(this).val();
	});
	var defs = jawnPhoneFlowsSync();
	var receptionist = defs.receptionist || {};
	$.ajax({
		url: '/manager/phone/ivr',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			enabled: $('#phone_app #phone_ivr_enabled').is(':checked') ? 'yes' : 'no',
			machine: $('#phone_app #phone_ivr_machine').val() || '',
			voice: receptionist.voice || '',
			bluetooth: $('#phone_app #phone_ivr_bluetooth').val() || '',
			greeting: receptionist.greeting || '',
			prompt: receptionist.prompt || '',
			voicemail: receptionist.voicemail || '',
			thanks: receptionist.thanks || '',
			hold: receptionist.hold || '',
			flows: JSON.stringify(flows),
			flow_defs: JSON.stringify(defs)
		},
		success: function (res) {
			if (res && res.ok) {
				status.text(jawnosT('IVR saved.'));
				if (typeof jawnPhoneSync === 'function') { jawnPhoneSync(); }
			} else {
				status.text(jawnosT('Could not save IVR.'));
			}
		},
		error: function () { status.text(jawnosT('Could not save IVR.')); }
	});
});

// ---- named flows ----------------------------------------------------------
// A flow is one voice and one set of words the gateway speaks, its own hold
// music, and what happens after the thanks. The list is drawn from the JSON the
// template embeds, so adding, renaming and deleting share the render path.

var jawnPhoneFlowDefs = null;
var jawnPhoneFlowOpen = {};
var jawnPhoneHoldLibrary = null;

function jawnPhoneFlowsEditor() { return $('#phone_app #phone_ivr_flows_editor'); }

function jawnPhoneFlowsInit() {
	var box = jawnPhoneFlowsEditor();
	if (!box.length || jawnPhoneFlowDefs) { return; }
	try { jawnPhoneFlowDefs = JSON.parse(box.attr('data-flow-defs') || '{}'); } catch (e) { jawnPhoneFlowDefs = {}; }
	jawnPhoneFlowsRender();
}

function jawnPhoneFlowVoices() {
	try { return JSON.parse(jawnPhoneFlowsEditor().attr('data-flow-voices') || '[]'); } catch (e) { return []; }
}

function jawnPhoneFlowDefaults() {
	try { return JSON.parse(jawnPhoneFlowsEditor().attr('data-flow-defaults') || '{}'); } catch (e) { return {}; }
}

function jawnPhoneFlowLabel(flow) {
	flow = flow || {};
	return flow.builtin ? jawnosT(flow.name || '') : (flow.name || '');
}

// The count beside a flow's name: how many of the six caller buckets it answers.
// An older save still says ivr for the receptionist, so that counts too.
function jawnPhoneFlowCount(key) {
	var count = 0;
	$('#phone_app .phone_app_ivr_flow').each(function () {
		var action = $(this).val();
		if (action === key) { count++; }
		else if (key === 'receptionist' && action === 'ivr') { count++; }
	});
	return count;
}

function jawnPhoneFlowCountText(count) {
	if (count === 1) { return jawnosT('1 caller'); }
	return count + ' ' + jawnosT('callers');
}

function jawnPhoneFlowCountsRefresh() {
	$('#phone_app .phone_app_ivr_flow_count').each(function () {
		var span = $(this);
		span.text(jawnPhoneFlowCountText(jawnPhoneFlowCount(span.attr('data-flow'))));
	});
}

// The messages a voicemail flow left. The list is the gateway's (the files are
// on that machine); Play is a link to the recording route, which asks the
// gateway for the bytes when the file is not on this one.
function jawnPhoneVoicemail(res) {
	var box = $('#phone_app #phone_ivr_voicemail');
	if (!box.length) { return; }
	var list = (res && res.voicemail) || [];
	var key = JSON.stringify($.map(list, function (m) { return (m.name || '') + ':' + (m.at || 0); }));
	if (box.attr('data-vm') === key) { return; }
	box.attr('data-vm', key).empty();
	if (!list.length) { box.append($('<div class="phone_app_ivr_vm_row"></div>').text(jawnosT('No messages yet.'))); return; }
	$.each(list, function (i, m) {
		var when = m.at ? new Date(m.at * 1000).toLocaleString() : '';
		var item = $('<div class="phone_app_ivr_vm_item"></div>');
		var row = $('<div class="phone_app_ivr_vm_row"></div>');
		row.append($('<span class="phone_app_ivr_vm_when"></span>').text(when));
		row.append($('<span class="phone_app_ivr_vm_ms"></span>').text(Math.round((m.ms || 0) / 1000) + 's'));
		row.append($('<a class="phone_app_ivr_vm_play" hint="Play"></a>')
			.attr('href', '/manager/sco/recording?name=' + encodeURIComponent(m.name || ''))
			.attr('target', '_blank')
			.attr('rel', 'noopener')
			.text(jawnosT('Play')));
		if (m.note_uuid) {
			row.append($('<a class="phone_app_ivr_vm_transcript" hint="Transcript"></a>')
				.attr('href', '#')
				.attr('data-note', m.note_uuid)
				.text(jawnosT('Transcript')));
		}
		item.append(row);
		if (m.note_uuid) {
			item.append($('<div class="phone_app_ivr_vm_words" hidden></div>'));
		}
		box.append(item);
	});
}

// A message's transcript is one expanding row, fetched by the note's uuid from
// the mailbox when it is first opened. It is not copied into the index: the
// Chat app owns the words, and the voicemail only points at them.
$(document).on('click', '#phone_app .phone_app_ivr_vm_transcript', function (e) {
	e.preventDefault();
	var link = $(this);
	var words = link.closest('.phone_app_ivr_vm_item').find('.phone_app_ivr_vm_words');
	if (!words.length) { return; }
	if (!words.prop('hidden')) { words.prop('hidden', true); return; }
	words.prop('hidden', false);
	if (words.attr('data-loaded') === 'yes') { return; }
	words.text(jawnosT('Opening…'));
	$.ajax({
		url: '/manager/sco/transcript',
		type: 'GET',
		dataType: 'json',
		data: { uuid: link.attr('data-note'), timestamp: Date.now() },
		success: function (res) {
			if (res && res.ok) {
				words.text(res.text || '');
				words.attr('data-loaded', 'yes');
			} else {
				words.text(jawnosT('The transcript is not available.'));
			}
		},
		error: function () { words.text(jawnosT('The transcript is not available.')); }
	});
});

// The hold dropdown lists what the gateway can actually play: none, the whole
// library shuffled, or one track. A stored track the gateway cannot see right
// now stays a choice, so opening a flow does not silently drop it.
function jawnPhoneFlowHoldFill(sel, tracks, current) {
	if (!sel || !sel.length) { return; }
	tracks = tracks || [];
	var value = (current !== undefined && current !== null) ? current : (sel.val() || '');
	var key = JSON.stringify(tracks);
	if (sel.attr('data-tracks') !== key) {
		sel.attr('data-tracks', key);
		sel.empty();
		sel.append($('<option>').val('').text(jawnosT('None')));
		sel.append($('<option>').val('shuffle').text(jawnosT('Shuffle all')));
		$.each(tracks, function (i, t) {
			if (!t || !t.id) { return; }
			sel.append($('<option>').val(t.id).text(t.label || t.id));
		});
	}
	if (value && value !== 'shuffle') {
		var known = false;
		sel.find('option').each(function () { if ($(this).val() === value) { known = true; } });
		if (!known) {
			var label = value.replace(/^.*\//, '').replace(/\.[A-Za-z0-9]+$/, '');
			sel.append($('<option>').val(value).text(label));
		}
	}
	sel.val(value || '');
}

// ---- the steps ------------------------------------------------------------
// A flow is an ordered list of steps. The old fixed sequence - greeting, ask
// for a name, thanks, then the after choice - is what a flow with no steps
// means, so a house that never opened the editor keeps speaking it. Order is
// the array's order; the DOM is the array (a drag moves the rows, a read takes
// them in the order they are left in).
function jawnPhoneFlowStepLabel(type) {
	var labels = {
		say: jawnosT('Say'),
		ask: jawnosT('Ask for a name'),
		keypad: jawnosT('Keypad menu'),
		hold: jawnosT('Hold music'),
		voicemail: jawnosT('Voicemail'),
		after: jawnosT('After')
	};
	return labels[type] || type;
}

function jawnPhoneFlowStepTypes() {
	return ['say', 'ask', 'keypad', 'hold', 'voicemail', 'after'];
}

// What a flow with no steps speaks. Kept beside the perl cleaner and the
// gateway so all three agree on the legacy order.
function jawnPhoneFlowStepLegacy() {
	return [
		{ type: 'say', text_key: 'greeting' },
		{ type: 'ask' },
		{ type: 'say', text_key: 'thanks' },
		{ type: 'after' }
	];
}

function jawnPhoneFlowStepsOf(flow) {
	var steps = (flow && $.isArray(flow.steps)) ? flow.steps : [];
	if (steps.length) { return steps; }
	return jawnPhoneFlowStepLegacy();
}

function jawnPhoneFlowStepDefault(type) {
	if (type === 'say') { return { type: 'say', text_key: 'greeting' }; }
	if (type === 'keypad') { return { type: 'keypad', text: '', timeout_ms: 5000, digits: {} }; }
	if (type === 'hold') { return { type: 'hold', seconds: 0 }; }
	return { type: type };
}

// One digit's menu: Ring, Reject and every flow. A digit left on Nothing is
// unmapped, so it carries on to the next step.
function jawnPhoneFlowDigitSelect(digit, value) {
	var sel = $('<select step-field="digit"></select>').attr('digit', digit);
	sel.append($('<option></option>').val('').text(jawnosT('Nothing')));
	sel.append($('<option></option>').val('ring').text(jawnosT('Ring')));
	sel.append($('<option></option>').val('reject').text(jawnosT('Reject')));
	$.each(jawnPhoneFlowKeys(), function (i, key) {
		sel.append($('<option></option>').val(key).text(jawnPhoneFlowLabel((jawnPhoneFlowDefs || {})[key] || {})));
	});
	sel.val(value || '');
	return sel;
}

function jawnPhoneFlowStepRow(step) {
	step = step || {};
	var type = step.type || 'say';
	var row = $('<div class="phone_app_ivr_step"></div>').attr('step-type', type);
	var head = $('<div class="phone_app_ivr_step_head"></div>');
	head.append($('<span class="phone_app_ivr_step_handle" hint="Drag to reorder" title="Drag to reorder"></span>').text('⋮⋮'));
	head.append($('<span class="phone_app_ivr_step_type"></span>').text(jawnPhoneFlowStepLabel(type)));
	head.append($('<button type="button" class="phone_app_ivr_step_remove" hint="Remove step"></button>').text(jawnosT('Remove')));
	row.append(head);

	var fields = $('<div class="phone_app_ivr_step_fields"></div>');
	if (type === 'say') {
		var sayLabel = $('<label></label>').text(jawnosT('Text'));
		var saySel = $('<select step-field="text_key"></select>');
		$.each([['greeting', jawnosT('Greeting')], ['prompt', jawnosT('Name prompt')], ['thanks', jawnosT('Thanks')], ['voicemail', jawnosT('Voicemail greeting')]], function (i, pair) {
			saySel.append($('<option></option>').val(pair[0]).text(pair[1]));
		});
		saySel.val(step.text_key || 'greeting');
		sayLabel.append(saySel);
		fields.append(sayLabel);
	}
	else if (type === 'keypad') {
		var textLabel = $('<label></label>').text(jawnosT('Spoken text'));
		textLabel.append($('<input type="text" step-field="text" maxlength="300">').val(step.text || ''));
		fields.append(textLabel);
		var timeoutLabel = $('<label></label>').text(jawnosT('Timeout (seconds)'));
		var timeout = (step.timeout_ms || 5000) / 1000;
		timeoutLabel.append($('<input type="number" step-field="timeout_s" min="1" max="30" step="1">').val(timeout));
		fields.append(timeoutLabel);
		fields.append($('<div class="phone_app_ivr_step_hint"></div>').text(jawnosT('A mapped digit jumps to its choice; any other digit, or no digit in time, carries on to the next step.')));
		var grid = $('<div class="phone_app_ivr_digits"></div>');
		$.each(['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'], function (i, digit) {
			var cell = $('<label class="phone_app_ivr_digit"></label>');
			cell.append($('<span></span>').text(digit));
			cell.append(jawnPhoneFlowDigitSelect(digit, (step.digits || {})[digit] || ''));
			grid.append(cell);
		});
		fields.append(grid);
	}
	else if (type === 'hold') {
		var secondsLabel = $('<label></label>').text(jawnosT('Seconds'));
		secondsLabel.append($('<input type="number" step-field="seconds" min="0" max="600" step="1">').val(step.seconds || 0));
		fields.append(secondsLabel);
		fields.append($('<div class="phone_app_ivr_step_hint"></div>').text(jawnosT('0 plays this flow\'s hold music until the caller leaves.')));
	}
	else if (type === 'ask') {
		fields.append($('<div class="phone_app_ivr_step_hint"></div>').text(jawnosT('Plays the name prompt, beeps, and records the caller\'s name.')));
	}
	else if (type === 'voicemail') {
		fields.append($('<div class="phone_app_ivr_step_hint"></div>').text(jawnosT('Plays the voicemail greeting, then records a message.')));
	}
	else if (type === 'after') {
		fields.append($('<div class="phone_app_ivr_step_hint"></div>').text(jawnosT('Uses the After choice: hold, voicemail or end.')));
	}
	row.append(fields);
	return row;
}

// The rows in the order they were left in. jQuery UI sortable moves the DOM
// node on drop, so the list order is the array order.
function jawnPhoneFlowStepsRead(item) {
	var steps = [];
	item.find('.phone_app_ivr_steps > .phone_app_ivr_step').each(function () {
		var row = $(this);
		var type = row.attr('step-type') || '';
		var step = { type: type };
		if (type === 'say') {
			step.text_key = row.find('[step-field="text_key"]').val() || 'greeting';
		}
		else if (type === 'keypad') {
			step.text = row.find('[step-field="text"]').val() || '';
			var seconds = parseFloat(row.find('[step-field="timeout_s"]').val());
			step.timeout_ms = isFinite(seconds) ? Math.round(seconds * 1000) : 5000;
			step.digits = {};
			row.find('[step-field="digit"]').each(function () {
				var digit = $(this).attr('digit');
				var target = $(this).val() || '';
				if (target) { step.digits[digit] = target; }
			});
		}
		else if (type === 'hold') {
			var hold = parseInt(row.find('[step-field="seconds"]').val(), 10);
			step.seconds = isFinite(hold) ? hold : 0;
		}
		steps.push(step);
	});
	return steps;
}

// The house drag helper is jQuery UI sortable (the taskbar's window order uses
// it, and the manager layout loads the touch punch), so a stylus or a finger
// drags the same handle a mouse does.
function jawnPhoneFlowStepsDragInit(scope) {
	$(scope || '#phone_app').find('.phone_app_ivr_steps').each(function () {
		var box = $(this);
		if (!box.length || box.hasClass('ui-sortable') || typeof box.sortable !== 'function') { return; }
		box.sortable({
			items: '> .phone_app_ivr_step',
			handle: '.phone_app_ivr_step_handle',
			axis: 'y',
			distance: 4,
			tolerance: 'pointer',
			placeholder: 'phone_app_ivr_step_placeholder',
			forcePlaceholderSize: true,
			start: function () { box.addClass('phone_app_ivr_steps_dragging'); },
			stop: function () {
				box.removeClass('phone_app_ivr_steps_dragging');
				// the DOM is the new order; read it back so a later render keeps it
				jawnPhoneFlowsSync();
			}
		});
	});
}

// A flow that is deleted takes every digit that named it with it, so no menu
// is left pointing at a reception nobody answers.
function jawnPhoneFlowDigitsDrop(key) {
	$.each(jawnPhoneFlowDefs || {}, function (i, flow) {
		if (!flow || !$.isArray(flow.steps)) { return; }
		$.each(flow.steps, function (j, step) {
			if (!step || step.type !== 'keypad' || !step.digits) { return; }
			$.each(step.digits, function (digit, target) {
				if (target === key) { delete step.digits[digit]; }
			});
		});
	});
}

function jawnPhoneFlowItem(key, flow) {
	var item = $('<div class="phone_app_ivr_flow_item"></div>').attr('flow', key);
	var head = $('<div class="phone_app_ivr_flow_head" hint="Edit flow"></div>');
	head.append($('<span class="phone_app_ivr_flow_item_name"></span>').text(jawnPhoneFlowLabel(flow)));
	head.append($('<span class="phone_app_ivr_flow_count"></span>').attr('data-flow', key));
	head.append($('<span class="phone_app_ivr_flow_more"></span>').text('▾'));
	item.append(head);

	var typeOptions = '';
	$.each(jawnPhoneFlowStepTypes(), function (i, t) {
		typeOptions += '<option value="' + t + '">' + jawnPhoneFlowStepLabel(t) + '</option>';
	});
	var edit = $(
		'<div class="phone_app_ivr_flow_edit" hidden>'
		+ '<label>' + jawnosT('Name') + '<input type="text" field="name"></label>'
		+ '<label>' + jawnosT('Voice') + '<select field="voice"></select></label>'
		+ '<label>' + jawnosT('Greeting') + '<textarea rows="2" field="greeting"></textarea></label>'
		+ '<label>' + jawnosT('Name prompt') + '<textarea rows="2" field="prompt"></textarea></label>'
		+ '<label>' + jawnosT('Voicemail greeting') + '<textarea rows="2" field="voicemail"></textarea></label>'
		+ '<div class="phone_app_ivr_greeting">'
		+ '<div class="phone_app_ivr_greeting_row">'
		+ '<button type="button" class="phone_app_ivr_greeting_record" hint="Record greeting">' + jawnosT('Record') + '</button>'
		+ '<button type="button" class="phone_app_ivr_greeting_stop" hint="Stop" hidden>' + jawnosT('Stop') + '</button>'
		+ '<button type="button" class="phone_app_ivr_greeting_play" hint="Play greeting">' + jawnosT('Play') + '</button>'
		+ '<button type="button" class="phone_app_ivr_greeting_remove" hint="Remove greeting">' + jawnosT('Remove') + '</button>'
		+ '</div>'
		+ '<input type="hidden" field="voicemail_greeting">'
		+ '<div class="phone_app_ivr_greeting_note"></div>'
		+ '</div>'
		+ '<label>' + jawnosT('Voicemail length (seconds)') + '<input type="number" field="voicemail_seconds" min="15" max="1800" step="1" hint="Voicemail length"></label>'
		+ '<label>' + jawnosT('Thanks') + '<textarea rows="1" field="thanks"></textarea></label>'
		+ '<label>' + jawnosT('Hold music') + '<select field="hold" hint="Hold music"></select></label>'
		+ '<label>' + jawnosT('After') + '<select field="after" hint="After">'
		+ '<option value="hold">' + jawnosT('Hold') + '</option>'
		+ '<option value="voicemail">' + jawnosT('Voicemail') + '</option>'
		+ '<option value="end">' + jawnosT('End') + '</option>'
		+ '</select></label>'
		+ '<div class="phone_app_ivr_steps_wrap">'
		+ '<div class="phone_app_ivr_steps_title">' + jawnosT('Steps') + '</div>'
		+ '<div class="phone_app_ivr_steps"></div>'
		+ '<div class="phone_app_ivr_step_add">'
		+ '<select class="phone_app_ivr_step_type_new" hint="Step type">' + typeOptions + '</select>'
		+ '<button type="button" class="phone_app_ivr_step_add_btn" hint="Add step">' + jawnosT('Add step') + '</button>'
		+ '</div></div>'
		+ '<div class="phone_app_ivr_flow_actions">'
		+ '<button type="button" class="phone_app_ivr_flow_rename" hint="Rename flow">' + jawnosT('Rename') + '</button>'
		+ (flow.builtin ? '' : '<button type="button" class="phone_app_ivr_flow_delete" hint="Delete flow">' + jawnosT('Delete') + '</button>')
		+ '</div>'
		+ '</div>'
	);
	item.append(edit);

	edit.find('[field="name"]').val(flow.name || '');
	edit.find('[field="greeting"]').val(flow.greeting || '');
	edit.find('[field="prompt"]').val(flow.prompt || '');
	edit.find('[field="voicemail"]').val(flow.voicemail || '');
	jawnPhoneFlowGreeting(edit, flow.voicemail_greeting || '');
	edit.find('[field="voicemail_seconds"]').val(flow.voicemail_seconds || 300);
	edit.find('[field="thanks"]').val(flow.thanks || '');
	edit.find('[field="after"]').val(flow.after || 'hold');

	var voices = jawnPhoneFlowVoices();
	var voice = edit.find('[field="voice"]');
	$.each(voices, function (i, v) {
		voice.append($('<option>').val(v.value).text(v.label || v.value));
	});
	voice.val(flow.voice || ((voices[0] || {}).value || ''));

	jawnPhoneFlowHoldFill(edit.find('[field="hold"]'), jawnPhoneHoldLibrary, flow.hold || '');

	var steps = jawnPhoneFlowStepsOf(flow);
	var stepsBox = edit.find('.phone_app_ivr_steps');
	$.each(steps, function (i, step) {
		stepsBox.append(jawnPhoneFlowStepRow(step));
	});

	if (jawnPhoneFlowOpen[key]) { head.addClass('on'); edit.prop('hidden', false); }
	return item;
}

// Read the editors back into the object, so a re-render (add, rename, delete)
// does not throw away edits made in the other open flows.
function jawnPhoneFlowsSync() {
	if (!jawnPhoneFlowDefs) { jawnPhoneFlowDefs = {}; }
	$('#phone_app .phone_app_ivr_flow_item').each(function () {
		var key = $(this).attr('flow');
		if (!key) { return; }
		var flow = jawnPhoneFlowDefs[key] || {};
		$(this).find('[field]').each(function () {
			flow[$(this).attr('field')] = $(this).val() || '';
		});
		// the steps are their own fields, and their DOM order is the order
		flow.steps = jawnPhoneFlowStepsRead($(this));
		jawnPhoneFlowDefs[key] = flow;
	});
	return jawnPhoneFlowDefs;
}

function jawnPhoneFlowKeys() {
	var keys = [];
	$.each(jawnPhoneFlowDefs || {}, function (key) { keys.push(key); });
	keys.sort(function (a, b) {
		var ba = jawnPhoneFlowDefs[a].builtin ? 0 : 1;
		var bb = jawnPhoneFlowDefs[b].builtin ? 0 : 1;
		if (ba !== bb) { return ba - bb; }
		return a < b ? -1 : (a > b ? 1 : 0);
	});
	return keys;
}

function jawnPhoneFlowValues(key) {
	var values = {};
	$('#phone_app .phone_app_ivr_flow_item').filter(function () { return $(this).attr('flow') === key; }).find('[field]').each(function () {
		values[$(this).attr('field')] = $(this).val() || '';
	});
	return values;
}

// The bucket selects offer Ring, Reject and every flow. A bucket pointing at a
// flow that has just been deleted falls back to what the bucket answers with
// when nothing is saved for it, which the server computed for the route.
function jawnPhoneFlowsBucketsRender() {
	var defs = jawnPhoneFlowDefs || {};
	var keys = jawnPhoneFlowKeys();
	var fallback = jawnPhoneFlowDefaults();
	$('#phone_app .phone_app_ivr_flow').each(function () {
		var sel = $(this);
		var current = sel.val();
		if (!current || (current !== 'ring' && current !== 'reject' && !defs[current])) {
			current = fallback[sel.attr('bucket')] || 'ring';
		}
		sel.empty();
		sel.append($('<option>').val('ring').text(jawnosT('Ring')));
		sel.append($('<option>').val('reject').text(jawnosT('Reject')));
		$.each(keys, function (i, key) {
			sel.append($('<option>').val(key).text(jawnPhoneFlowLabel(defs[key])));
		});
		sel.val(current);
	});
}

function jawnPhoneFlowsRender() {
	var list = $('#phone_app #phone_ivr_flow_list');
	if (!list.length) { return; }
	jawnPhoneFlowsSync();
	list.empty();
	$.each(jawnPhoneFlowKeys(), function (i, key) {
		list.append(jawnPhoneFlowItem(key, jawnPhoneFlowDefs[key]));
	});
	jawnPhoneFlowStepsDragInit(list);
	jawnPhoneFlowsBucketsRender();
	jawnPhoneFlowCountsRefresh();
}

function jawnPhoneFlowSlug(name) {
	var slug = (name || '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').substr(0, 30);
	if (!slug) { slug = 'flow'; }
	var key = slug, n = 1;
	while ((jawnPhoneFlowDefs || {})[key]) {
		n++;
		key = slug.substr(0, 27) + '_' + n;
	}
	return key;
}

$(document).on('click', '#phone_app .phone_app_ivr_flow_head', function () {
	var item = $(this).closest('.phone_app_ivr_flow_item');
	var key = item.attr('flow');
	var edit = item.find('.phone_app_ivr_flow_edit');
	var open = edit.prop('hidden');
	// an accordion: opening one flow folds the others, so the list stays short
	if (open) {
		$('#phone_app .phone_app_ivr_flow_item').each(function () {
			var other = $(this);
			if (other.is(item)) { return; }
			other.find('.phone_app_ivr_flow_edit').prop('hidden', true);
			other.find('.phone_app_ivr_flow_head').removeClass('on');
			jawnPhoneFlowOpen[other.attr('flow')] = false;
		});
	}
	jawnPhoneFlowOpen[key] = open;
	$(this).toggleClass('on', open);
	edit.prop('hidden', !open);
});

$(document).on('click', '#phone_app #phone_ivr_flow_add', function (e) {
	e.preventDefault();
	jawnPhoneFlowsInit();
	jawnPhoneFlowsSync();
	var name = window.prompt(jawnosT('Name this flow'), jawnosT('New flow'));
	if (name === null) { return; }
	name = (name || '').replace(/^\s+|\s+$/g, '');
	if (!name) { return; }
	var key = jawnPhoneFlowSlug(name);
	var source = jawnPhoneFlowDefs.receptionist || {};
	jawnPhoneFlowDefs[key] = {
		name: name,
		voice: source.voice || '',
		greeting: source.greeting || '',
		prompt: source.prompt || '',
		voicemail: source.voicemail || '',
		voicemail_greeting: source.voicemail_greeting || '',
		voicemail_seconds: source.voicemail_seconds || 300,
		thanks: source.thanks || '',
		hold: source.hold || '',
		after: source.after || 'hold',
		builtin: 0
	};
	jawnPhoneFlowOpen[key] = true;
	jawnPhoneFlowsRender();
});

$(document).on('click', '#phone_app .phone_app_ivr_flow_rename', function (e) {
	e.stopPropagation();
	var item = $(this).closest('.phone_app_ivr_flow_item');
	var key = item.attr('flow');
	jawnPhoneFlowsSync();
	var flow = jawnPhoneFlowDefs[key];
	if (!flow) { return; }
	var name = window.prompt(jawnosT('Name this flow'), flow.name || '');
	if (name === null) { return; }
	name = (name || '').replace(/^\s+|\s+$/g, '');
	if (!name) { return; }
	flow.name = name;
	jawnPhoneFlowOpen[key] = true;
	jawnPhoneFlowsRender();
});

// Deleting a flow is the house's two-press rule, like blocking a number.
$(document).on('click', '#phone_app .phone_app_ivr_flow_delete', function (e) {
	e.stopPropagation();
	var button = $(this);
	var item = button.closest('.phone_app_ivr_flow_item');
	var key = item.attr('flow');
	jawnPhoneFlowsSync();
	if (!jawnPhoneFlowDefs[key] || jawnPhoneFlowDefs[key].builtin) { return; }
	if (button.attr('armed') !== 'yes') {
		button.attr('armed', 'yes').data('label', button.text()).text(jawnosT('Press again to delete'));
		setTimeout(function () {
			button.attr('armed', 'no').text(button.data('label') || jawnosT('Delete'));
		}, 3000);
		return;
	}
	jawnPhoneFlowDigitsDrop(key);
	delete jawnPhoneFlowDefs[key];
	delete jawnPhoneFlowOpen[key];
	jawnPhoneFlowsRender();
});

// Add step: choose the kind first, then the row appears with its own fields.
$(document).on('click', '#phone_app .phone_app_ivr_step_add_btn', function (e) {
	e.preventDefault();
	e.stopPropagation();
	var item = $(this).closest('.phone_app_ivr_flow_item');
	var key = item.attr('flow');
	jawnPhoneFlowsSync();
	var flow = jawnPhoneFlowDefs[key];
	if (!flow) { return; }
	flow.steps = jawnPhoneFlowStepsOf(flow);
	if (flow.steps.length >= 20) {
		window.alert(jawnosT('A flow can have at most 20 steps.'));
		return;
	}
	var type = item.find('.phone_app_ivr_step_type_new').val() || 'say';
	flow.steps.push(jawnPhoneFlowStepDefault(type));
	jawnPhoneFlowOpen[key] = true;
	jawnPhoneFlowsRender();
});

// Remove one step. The rest keep their order.
$(document).on('click', '#phone_app .phone_app_ivr_step_remove', function (e) {
	e.preventDefault();
	e.stopPropagation();
	var row = $(this).closest('.phone_app_ivr_step');
	var item = row.closest('.phone_app_ivr_flow_item');
	var key = item.attr('flow');
	jawnPhoneFlowsSync();
	var flow = jawnPhoneFlowDefs[key];
	if (!flow) { return; }
	var index = item.find('.phone_app_ivr_steps > .phone_app_ivr_step').index(row);
	flow.steps = jawnPhoneFlowStepsOf(flow);
	if (index >= 0) { flow.steps.splice(index, 1); }
	jawnPhoneFlowOpen[key] = true;
	jawnPhoneFlowsRender();
});

$(document).on('change', '#phone_app .phone_app_ivr_flow', function () {
	jawnPhoneFlowCountsRefresh();
});

// ---- a flow's recorded voicemail greeting --------------------------------
// The greeting is either the flow's typed text or one recorded WAV the house
// holds. Record captures from the microphone with MediaRecorder, uploads the
// bytes, and the route keeps a WAV and returns its path; Save is what puts
// that path on the flow. Play asks the route for the file, and Remove goes
// back to the spoken text. Everything a person sees goes through jawnosT.
var jawnPhoneGreetingRecorder = null;
var jawnPhoneGreetingStream = null;
var jawnPhoneGreetingChunks = [];
var jawnPhoneGreetingTimer = null;
var jawnPhoneGreetingAudio = null;

function jawnPhoneGreetingStatus(edit, text) {
	$(edit).find('.phone_app_ivr_greeting_note').text(text || '');
}

function jawnPhoneFlowGreeting(edit, path) {
	edit = $(edit);
	path = path || '';
	edit.find('[field="voicemail_greeting"]').val(path);
	edit.find('.phone_app_ivr_greeting_play, .phone_app_ivr_greeting_remove').prop('disabled', !path);
	jawnPhoneGreetingStatus(edit, path ? jawnosT('A recorded greeting is in use.') : jawnosT('The spoken text is used.'));
}

function jawnPhoneGreetingIdle() {
	if (jawnPhoneGreetingTimer) { clearTimeout(jawnPhoneGreetingTimer); jawnPhoneGreetingTimer = null; }
	if (jawnPhoneGreetingStream) {
		jawnPhoneGreetingStream.getTracks().forEach(function (t) { try { t.stop(); } catch (e) {} });
		jawnPhoneGreetingStream = null;
	}
	$('#phone_app .phone_app_ivr_greeting_record').prop('hidden', false);
	$('#phone_app .phone_app_ivr_greeting_stop').prop('hidden', true);
}

function jawnPhoneGreetingStop() {
	if (jawnPhoneGreetingTimer) { clearTimeout(jawnPhoneGreetingTimer); jawnPhoneGreetingTimer = null; }
	var rec = jawnPhoneGreetingRecorder;
	jawnPhoneGreetingRecorder = null;
	// the recorder's own stop collects the last chunk; the stream and the
	// buttons go back only once it has, in onstop
	if (rec && rec.state !== 'inactive') {
		try { rec.stop(); return; } catch (e) {}
	}
	jawnPhoneGreetingIdle();
}

function jawnPhoneGreetingUpload(edit, key, type) {
	var blob = new Blob(jawnPhoneGreetingChunks, { type: type || 'audio/webm' });
	jawnPhoneGreetingChunks = [];
	if (!blob.size) { jawnPhoneGreetingStatus(edit, jawnosT('Nothing was recorded.')); return; }
	if (blob.size > 2 * 1024 * 1024) { jawnPhoneGreetingStatus(edit, jawnosT('That recording is too long.')); return; }
	jawnPhoneGreetingStatus(edit, jawnosT('Saving the recording…'));
	$.ajax({
		url: '/manager/phone/greeting?flow=' + encodeURIComponent(key || '') + '&timestamp=' + Date.now(),
		type: 'POST',
		processData: false,
		contentType: blob.type || 'audio/webm',
		data: blob,
		dataType: 'json',
		success: function (res) {
			if (res && res.ok && res.path) {
				jawnPhoneFlowGreeting(edit, res.path);
				if (jawnPhoneFlowDefs && jawnPhoneFlowDefs[key]) { jawnPhoneFlowDefs[key].voicemail_greeting = res.path; }
				jawnPhoneGreetingStatus(edit, jawnosT('Recorded. Press Save to keep it.'));
			}
			else if (res && res.error === 'too long') { jawnPhoneGreetingStatus(edit, jawnosT('The greeting must be a minute or less.')); }
			else { jawnPhoneGreetingStatus(edit, jawnosT('Could not save the recording.')); }
		},
		error: function () { jawnPhoneGreetingStatus(edit, jawnosT('Could not save the recording.')); }
	});
}

$(document).on('click', '#phone_app .phone_app_ivr_greeting_record', function (e) {
	e.preventDefault();
	e.stopPropagation();
	if (jawnPhoneGreetingRecorder) { return; }
	var button = $(this);
	var edit = button.closest('.phone_app_ivr_flow_edit');
	var key = button.closest('.phone_app_ivr_flow_item').attr('flow') || '';
	if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || !window.MediaRecorder) {
		jawnPhoneGreetingStatus(edit, jawnosT('This device cannot record audio.'));
		return;
	}
	jawnPhoneGreetingStatus(edit, jawnosT('Recording… press Stop when you are done.'));
	navigator.mediaDevices.getUserMedia({ audio: true }).then(function (stream) {
		var rec = null;
		try { rec = new MediaRecorder(stream); } catch (err) { rec = null; }
		if (!rec) {
			stream.getTracks().forEach(function (t) { try { t.stop(); } catch (err2) {} });
			jawnPhoneGreetingStatus(edit, jawnosT('This device cannot record audio.'));
			return;
		}
		jawnPhoneGreetingStream = stream;
		jawnPhoneGreetingChunks = [];
		jawnPhoneGreetingRecorder = rec;
		rec.ondataavailable = function (ev) { if (ev.data && ev.data.size) { jawnPhoneGreetingChunks.push(ev.data); } };
		rec.onstop = function () {
			var kind = rec.mimeType || 'audio/webm';
			jawnPhoneGreetingIdle();
			jawnPhoneGreetingUpload(edit, key, kind);
		};
		rec.start();
		button.prop('hidden', true);
		edit.find('.phone_app_ivr_greeting_stop').prop('hidden', false);
		// a greeting is a minute at most; the route refuses anything longer
		jawnPhoneGreetingTimer = setTimeout(function () { jawnPhoneGreetingStop(); }, 60000);
	}).catch(function () {
		jawnPhoneGreetingIdle();
		jawnPhoneGreetingStatus(edit, jawnosT('I could not reach the microphone.'));
	});
});

$(document).on('click', '#phone_app .phone_app_ivr_greeting_stop', function (e) {
	e.preventDefault();
	e.stopPropagation();
	jawnPhoneGreetingStop();
});

$(document).on('click', '#phone_app .phone_app_ivr_greeting_play', function (e) {
	e.preventDefault();
	e.stopPropagation();
	var edit = $(this).closest('.phone_app_ivr_flow_edit');
	var path = edit.find('[field="voicemail_greeting"]').val() || '';
	if (!path) { jawnPhoneGreetingStatus(edit, jawnosT('There is no recorded greeting.')); return; }
	try {
		if (!jawnPhoneGreetingAudio) { jawnPhoneGreetingAudio = new Audio(); }
		jawnPhoneGreetingAudio.src = '/manager/phone/greeting?path=' + encodeURIComponent(path) + '&timestamp=' + Date.now();
		jawnPhoneGreetingAudio.play();
	} catch (err) { jawnPhoneGreetingStatus(edit, jawnosT('The greeting could not be played.')); }
});

$(document).on('click', '#phone_app .phone_app_ivr_greeting_remove', function (e) {
	e.preventDefault();
	e.stopPropagation();
	var button = $(this);
	var edit = button.closest('.phone_app_ivr_flow_edit');
	var key = button.closest('.phone_app_ivr_flow_item').attr('flow') || '';
	jawnPhoneFlowGreeting(edit, '');
	if (jawnPhoneFlowDefs && jawnPhoneFlowDefs[key]) { jawnPhoneFlowDefs[key].voicemail_greeting = ''; }
	jawnPhoneGreetingStatus(edit, jawnosT('The spoken text is used. Press Save to keep it.'));
});

// dial pad
$(document).on('click', '#phone_app .phone_app_key', function () {
	jawnPhoneApp.number += $(this).attr('key');
	$('#phone_app #phone_app_display').text(jawnPhoneApp.number);
});
$(document).on('click', '#phone_app .phone_app_dial_btn', function () {
	var n = jawnPhoneApp.number;
	if (!n) { jawnPhoneAppStatus('Dial a number first.'); return; }
	jawnPhoneAppStatus('Calling ' + n + '…');
	$.ajax({
		url: '/manager/phone/dial',
		type: 'POST',
		data: { number: n, timestamp: Date.now() },
		success: function (res) {
			if (res && res.ok) {
				jawnPhoneApp.number = '';
				$('#phone_app #phone_app_display').text('');
				jawnPhoneAppStatus('Calling ' + n + '…');
			} else {
				jawnPhoneAppStatus((res && res.error) || 'Could not dial.');
			}
		},
		error: function () { jawnPhoneAppStatus('Could not dial.'); }
	});
});

// Block a recent call: the first press arms it, the second within two seconds
// does it - the house's two-press habit for anything that leaves a lasting rule
$(document).on('click', '#phone_app .phone_app_block', function (e) {
	e.stopPropagation();
	var b = $(this);
	if (b.attr('armed') !== 'yes') {
		b.attr('armed', 'yes');
		b.css({ 'background-color': 'red', 'border-radius': '50%', 'padding': '2px' });
		setTimeout(function () {
			b.css({ 'background-color': '', 'border-radius': '', 'padding': '' });
			b.attr('armed', 'no');
		}, 2000);
		jawnPhoneAppStatus('Press again to block');
		return;
	}
	b.attr('armed', 'no');
	b.css({ 'background-color': '', 'border-radius': '', 'padding': '' });
	var row = b.closest('.phone_app_row');
	var number = row.attr('number') || row.attr('app') || '';
	if (!number) { jawnPhoneAppStatus('No number to block.'); return; }
	$.ajax({
		url: '/manager/box_office/blacklist/number',
		type: 'POST',
		data: { timestamp: Date.now(), number: number, app: row.attr('app') || '', name: row.attr('app') || '' },
		success: function (res) {
			if (res && res.ok) {
				jawnPhoneAppStatus('Blocked ' + res.number);
				if (typeof jawnPhoneSync === 'function') { jawnPhoneSync(); }
				jawnPhoneAppReload('recent');
			} else {
				jawnPhoneAppStatus('Enter a number.');
			}
		},
		error: function () { jawnPhoneAppStatus('Could not block.'); }
	});
});

// Unblock: the same two presses. The number comes off the desk's list, so it
// rings again (and may ask for a ticket at the door again)
$(document).on('click', '#phone_app .phone_app_unblock', function (e) {
	e.stopPropagation();
	var b = $(this);
	if (b.attr('armed') !== 'yes') {
		b.attr('armed', 'yes');
		setTimeout(function () { b.attr('armed', 'no'); }, 2000);
		jawnPhoneAppStatus('Press again to unblock');
		return;
	}
	b.attr('armed', 'no');
	$.ajax({
		url: '/manager/box_office/blacklist/remove',
		type: 'POST',
		data: { timestamp: Date.now(), stamp: b.attr('stamp') },
		success: function () {
			jawnPhoneAppStatus('Unblocked ' + (b.attr('number') || ''));
			if (typeof jawnPhoneSync === 'function') { jawnPhoneSync(); }
			jawnPhoneAppReload('blocked');
		},
		error: function () { jawnPhoneAppStatus('Could not unblock.'); }
	});
});

// a contact tap fills the dial pad; a recent tap opens the caller's own thread
$(document).on('click', '#phone_app .phone_app_row', function () {
	var number = $(this).attr('number');
	var app = $(this).attr('app');
	if (number) {
		jawnPhoneApp.number = number;
		$('#phone_app #phone_app_display').text(number);
		$('#phone_app .phone_app_tab[pane="dial"]').trigger('click');
	} else if (app && typeof appointmentGrabber === 'function') {
		appointmentGrabber(app, Date.now());
	}
});

// a person may keep more than one line: each is its own tap, dialing that one,
// while the row around them still dials the first
$(document).on('click', '#phone_app .phone_app_line', function (e) {
	e.stopPropagation();
	var n = $(this).attr('dial');
	if (!n) { return; }
	jawnPhoneApp.number = n;
	$('#phone_app #phone_app_display').text(n);
	$('#phone_app .phone_app_tab[pane="dial"]').trigger('click');
});

// ---- native (window.JawnContacts) ----------------------------------------
function jawnPhoneAppArm() {
	if (!window.JawnContacts || typeof window.JawnContacts.available !== 'function') { return; }
	if (window.JawnContacts.available() !== 'yes') {
		try { window.JawnContacts.request(); } catch (e) { }
	}
	window.__jawnContactsEvent = function (type, payload) {
		if (type === 'permission' && payload && payload.granted) { jawnPhoneAppNativeContacts(); }
		if (type === 'screening') { jawnPhoneAppCallerId(); }
	};
	jawnPhoneAppCallerId();
}

// The Caller ID (call screening) role. Held, the app learns who is calling at
// ring; not held, the button asks for the role.
function jawnPhoneAppCallerId() {
	if (!window.JawnContacts || typeof window.JawnContacts.screeningRole !== 'function') { return; }
	var held = false;
	try { held = window.JawnContacts.screeningRole() === 'yes'; } catch (e) { }
	$('#phone_app .phone_app_callerid').toggle(!held);
	$('#phone_app .phone_app_callerid_state').text(held ? 'Caller ID is on' : '');
	// Without the phone role the system dialer answers the call and the house
	// never sees it, so the reception cannot work until this is on.
	var dialer = 'yes';
	try { dialer = (window.JawnPhone && typeof window.JawnPhone.dialerRole === 'function') ? window.JawnPhone.dialerRole() : 'yes'; } catch (e) { }
	$('#phone_app .phone_app_dialer').toggle(dialer !== 'yes');
}
$(document).on('click', '#phone_app .phone_app_dialer', function () {
	if (window.JawnPhone && typeof window.JawnPhone.requestDialer === 'function') {
		try { window.JawnPhone.requestDialer(); } catch (e) { }
	}
});

$(document).on('click', '#phone_app .phone_app_callerid', function () {
	if (window.JawnContacts && typeof window.JawnContacts.requestScreening === 'function') {
		window.JawnContacts.requestScreening();
	}
});

function jawnPhoneAppNativeContacts() {
	if (!window.JawnContacts || typeof window.JawnContacts.list !== 'function') return;
	try {
		var data = JSON.parse(window.JawnContacts.list(''));
		if (!data || !data.contacts || !data.contacts.length) return;
		var pane = $('#phone_app .phone_app_pane[pane="known"]');
		var list = $('<div class="phone_app_list"></div>');
		$.each(data.contacts, function (i, c) {
			var number = (c.numbers && c.numbers[0] && c.numbers[0].number) || '';
			var row = $('<div class="phone_app_row"></div>').attr('number', number).attr('app', c.name || '');
			$('<span class="phone_app_avatar"></span>')
				.append($('<img>').attr('src', '/images/decipherable/phone.png')).appendTo(row);
			$('<span class="phone_app_name"></span>').text(c.name || '').appendTo(row);
			$('<span class="phone_app_sub"></span>').text(number).appendTo(row);
			list.append(row);
		});
		pane.find('.phone_app_list, .phone_app_empty').remove();
		pane.prepend(list);
	} catch (e) { }
}

$(document).ready(function () {
	if ($('#phone_app').length) { jawnPhoneAppRender(); jawnPhoneAppArm(); }
	// a call that ended while the app was away is still waiting to be filed
	jawnPhoneAppFileCalls();
});

// ---- call routing for one number ----------------------------------------
// A person or a number can answer differently from the rest of their bucket.
// The sheet is one number at a time: the resolved route is fetched when it
// opens, so "Follow the person" shows what the relationship would do.

function jawnPhoneRouteOpen(number, app) {
	var sheet = $('#phone_app #phone_route_sheet');
	if (!number) { return; }
	sheet.attr('number', number).attr('app', app || '');
	$('#phone_app #phone_route_who').text((app ? jawnPhoneRouteName(app) + ' · ' : '') + number);
	$('#phone_app #phone_route_note').text('');
	$('#phone_app #phone_route_status').text('');
	$('#phone_app .phone_route_choice').removeClass('on');
	sheet.show();
	$.ajax({
		url: '/manager/phone/route',
		type: 'GET',
		dataType: 'json',
		data: { number: number, timestamp: Date.now() },
		success: function (res) {
			if (!res) { return; }
			var flow = res.flow || 'ring';
			var pick = (res.source === 'number') ? flow : 'default';
			$('#phone_app .phone_route_choice[route="' + pick + '"]').addClass('on');
			var source = res.source || '';
			var note = 'Now: ' + flow;
			if (source === 'number') { note += ' — set for this number'; }
			else if (source === 'off') { note += ' — the reception flow is off'; }
			else if (source) { note += ' — from ' + source; }
			$('#phone_app #phone_route_note').text(note);
		}
	});
}

function jawnPhoneRouteName(app) {
	var formatted = $('.people_person_link[app="' + app + '"]').text();
	if (formatted) { return formatted; }
	return app.replace(/_/g, ' ');
}

$(document).on('click', '#phone_app .phone_app_row_route', function (e) {
	e.stopPropagation();
	var icon = $(this);
	var row = icon.closest('.phone_app_row');
	var number = icon.attr('number') || row.attr('number') || '';
	jawnPhoneRouteOpen(number, icon.attr('app') || row.attr('app') || '');
});

$(document).on('click', '#phone_app #phone_route_close', function () {
	$('#phone_app #phone_route_sheet').hide();
});

$(document).on('click', '#phone_app .phone_route_choice', function () {
	var sheet = $('#phone_app #phone_route_sheet');
	var flow = $(this).attr('route');
	var number = sheet.attr('number');
	$.ajax({
		url: '/manager/phone/route',
		type: 'POST',
		dataType: 'json',
		data: { number: number, flow: flow, timestamp: Date.now() },
		success: function (res) {
			if (!res || !res.ok) {
				$('#phone_app #phone_route_status').text('Could not save.');
				return;
			}
			$('#phone_app .phone_route_choice').removeClass('on');
			$('#phone_app .phone_route_choice[route="' + flow + '"]').addClass('on');
			$('#phone_app #phone_route_status').text('Saved.');
			var saved = (flow === 'default') ? '' : flow;
			$('#phone_app .phone_app_row_route').filter(function () {
				return $(this).attr('number') === number;
			}).attr('route', saved);
			if (typeof jawnPhoneSync === 'function') { jawnPhoneSync(); }
			var resolved = res.resolved || {};
			$('#phone_app #phone_route_note').text(resolved.flow ? ('Now: ' + resolved.flow) : '');
		},
		error: function () { $('#phone_app #phone_route_status').text('Could not save.'); }
	});
});

// ---- the gateway's own state, on the IVR pane ---------------------------

// ---- the caller's words, live, on the IVR pane -----------------------------
// The gateway pushes a line as the caller finishes it and the sentence being
// said as it is recognised, on the phone's websocket. The same lines are in
// /manager/sco/status, so a pane opened in the middle of a call fills in what it
// missed - the push is the fast path, never the only one.
var jawnPhoneTranscriptSeen = 0;
var jawnPhoneTranscriptCall = '';

function jawnPhoneTranscriptClear() {
	jawnPhoneTranscriptSeen = 0;
	$('#phone_app #phone_transcript_lines').empty();
}

function jawnPhoneTranscriptLine(line) {
	if (!line || !line.text) { return; }
	var box = $('#phone_app #phone_transcript_lines');
	if (!box.length) { return; }
	$('<div class="phone_transcript_bubble"></div>')
		.attr('who', line.who || 'caller')
		.text(line.text)
		.appendTo(box);
	jawnPhoneTranscriptSeen++;
	$('#phone_app #phone_transcript').prop('hidden', false);
	box.scrollTop(box[0].scrollHeight);
}

function jawnPhoneTranscriptPartial(text) {
	var box = $('#phone_app #phone_transcript_lines');
	if (!box.length) { return; }
	var partial = box.find('.phone_transcript_bubble.phone_transcript_partial');
	if (!text) { partial.remove(); return; }
	if (!partial.length) {
		partial = $('<div class="phone_transcript_bubble phone_transcript_partial"></div>').appendTo(box);
	}
	partial.text(text);
	$('#phone_app #phone_transcript').prop('hidden', false);
	box.scrollTop(box[0].scrollHeight);
}

// The poll repeats every two seconds; only the lines it has not drawn yet are
// added, and a new call starts the bubbles over.
function jawnPhoneTranscriptSync(callId, lines, partial, note, caller) {
	if ((callId || '') !== jawnPhoneTranscriptCall) {
		// a new call (or none) is not the one this device was listening to
		if (jawnScreenRtc.pc) { jawnPhoneRtcStop(); }
		jawnPhoneTranscriptCall = callId || '';
		jawnPhoneTranscriptClear();
	}
	$.each((lines || []).slice(jawnPhoneTranscriptSeen), function (i, line) {
		jawnPhoneTranscriptLine(line);
	});
	jawnPhoneTranscriptPartial(partial || '');
	$('#phone_app #phone_transcript_note').text(note || '');
	var who = caller && (caller.name || caller.number) ? (caller.name || caller.number) : '';
	$('#phone_app #phone_transcript_title').text(who ? (jawnosT('Call from: ') + who) : jawnosT('Live transcript'));
	$('#phone_app #phone_transcript').prop('hidden',
		!(jawnPhoneTranscriptSeen || partial) && !note);
}

// A push arrives from another window/machine; the pane only draws it when it is
// on the IVR tab, and the status poll fills in whatever came before it opened.
function jawnPhoneTranscriptPushed(data) {
	if (!data) { return; }
	if (data.call_id && jawnPhoneTranscriptCall && data.call_id !== jawnPhoneTranscriptCall) {
		jawnPhoneTranscriptCall = data.call_id;
		jawnPhoneTranscriptClear();
	}
	if (data.line) { jawnPhoneTranscriptLine(data.line); }
	else if (typeof data.partial === 'string') { jawnPhoneTranscriptPartial(data.partial); }
}

// ---- Connect me -----------------------------------------------------------
// The bridge itself lives in screening.js, which every page loads: the floating
// screening panel draws on any device, so the WebRTC peer cannot live only in
// the Phone app's script. These names are the pane's own handle on it.
function jawnPhoneRtcConnect() { jawnScreenRtcConnect(jawnPhoneTranscriptCall); }
function jawnPhoneRtcStop(notify) { jawnScreenRtcStop(notify); }

var jawnPhoneGatewayTimer = null;

function jawnPhoneGatewayPoll(on) {
	if (jawnPhoneGatewayTimer) {
		clearInterval(jawnPhoneGatewayTimer);
		jawnPhoneGatewayTimer = null;
	}
	if (on) { jawnPhoneGatewayTimer = setInterval(jawnPhoneGatewayState, 2000); }
}

function jawnPhoneGatewayState() {
	$.ajax({
		url: '/manager/sco/status',
		type: 'GET',
		dataType: 'json',
		data: { timestamp: Date.now(), number: jawnPhoneAppNumber() },
		success: function (res) {
			var state = (res && res.state) || 'unavailable';
			var label = 'Gateway: ' + state;
			if (res && res.helper === 0) { label = 'Gateway: the helper is not built on this machine'; }
			else if (state === 'in_call') { label = 'Gateway: a call is up'; }
			else if (state === 'armed') { label = 'Gateway: listening for the next call'; }
			// a 2.4 GHz connection shares the antenna with Bluetooth on a combo
			// card: the caller breaks up instead of anything failing loudly
			if (res && res.wifi === '2.4') {
				label = label + ' - ' + jawnosT('this machine is on 2.4 GHz WiFi, so the caller will break up');
			}
			$('#phone_app #phone_ivr_gateway_state').text(label);
			// the gateway owns the music library, so it is the one that says
			// which tracks the dropdown may offer
			jawnPhoneHoldTracks(res && res.hold_tracks);
			jawnPhoneVoicemail(res);
			jawnPhoneTranscriptSync(res && res.call_id, res && res.transcript, res && res.partial, res && res.transcript_note, res && res.caller);
			if (jawnPhoneConnectMeWanted && (state === 'in_call' || state === 'done')) {
				jawnPhoneConnectMeWanted = false;
				jawnPhoneRtcConnect();
			}
		},
		error: function () { $('#phone_app #phone_ivr_gateway_state').text('Gateway: not answering'); }
	});
}

// The hold dropdowns list what the gateway can actually play: none, the whole
// library shuffled, or one track. The list is rebuilt only when it changes, so
// a choice being made is not yanked out from under the person.
function jawnPhoneHoldTracks(tracks) {
	if (!tracks) { return; }
	jawnPhoneHoldLibrary = tracks;
	$('#phone_app .phone_app_ivr_flow_edit [field="hold"]').each(function () {
		jawnPhoneFlowHoldFill($(this), tracks);
	});
}

$(document).on('click', '#phone_app .phone_app_tab', function () {
	var pane = $(this).attr('pane');
	jawnPhoneGatewayPoll(pane === 'ivr');
	if (pane === 'ivr') { jawnPhoneGatewayState(); }
});

$(document).on('click', '#phone_app #phone_ivr_arm', function (e) {
	e.preventDefault();
	var label = $('#phone_app #phone_ivr_gateway_state');
	label.text(jawnosT('Arming…'));
	jawnPhoneFlowsInit();
	// The gateway is armed with the receptionist flow: that is what the older
	// top-level prompt rows mean, and the bucket matrix picks a flow per caller.
	var receptionist = jawnPhoneFlowValues('receptionist');
	$.ajax({
		url: '/manager/sco/arm',
		type: 'POST',
		dataType: 'json',
		data: {
			timestamp: Date.now(),
			voice: receptionist.voice || '',
			bluetooth: $('#phone_app #phone_ivr_bluetooth').val() || '',
			greeting: receptionist.greeting || '',
			prompt: receptionist.prompt || '',
			thanks: receptionist.thanks || '',
			hold: receptionist.hold || ''
		},
		success: function (res) {
			if (res && res.ok) { jawnPhoneGatewayState(); }
			else { label.text('Gateway: ' + ((res && res.error) || 'could not arm')); }
		},
		error: function () { label.text('Gateway: not answering'); }
	});
});

// A face button lands on the Phone app with a pane to open; without this the
// status poll only starts on an IVR-tab click, and the auto-connect above would
// never see a call.
$(function () {
	if (!jawnPhoneConnectMeWanted) { return; }
	setTimeout(function () {
		if ($('#phone_app').length) {
			$('#phone_app .phone_app_tab[pane="ivr"]').trigger('click');
		}
	}, 400);
});

// The flow list is drawn from the JSON the template embeds, so it is ready as
// soon as the pane is.
$(function () {
	jawnPhoneFlowsInit();
});
