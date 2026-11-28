// The held-write card. A write the Guide proposed - spoken on a watch, or
// staged from the browser - is held in this machine's cache until a person
// confirms it. This card lists what is held and gives the two buttons a spoken
// "yes" would otherwise be the only way to press. There is no poller: the
// server pushes helpPendingReload when the list changes (store, take, confirm
// or cancel), and opening the Guide loads it once.
var jawnos_help_pending_busy = false;

function helpPendingT(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function helpPendingContainer() { return $('.wind[app="help"] #help_pending'); }

function helpPendingHide() {
	var el = helpPendingContainer();
	if (el.length) { el.hide().empty(); }
}

function helpPendingRow(a) {
	var row = $('<div class="help_pending_row" style="display:flex;gap:8px;align-items:center;padding:4px 0;"></div>');
	$('<span class="help_pending_label" style="flex:1;min-width:0;font-size:13px;line-height:1.3;overflow-wrap:break-word;"></span>')
		.text(a && a.label ? String(a.label) : helpPendingT('A held change'))
		.appendTo(row);
	$('<button type="button" class="button help_pending_confirm" style="padding:4px 10px;border-radius:8px;border:2px solid var(--line);cursor:var(--jawnos-cursor-pointer, pointer);font-weight:bold;"></button>')
		.attr('data-id', a.id)
		.attr('hint', helpPendingT('Confirm this change'))
		.text(helpPendingT('Confirm'))
		.appendTo(row);
	$('<button type="button" class="button help_pending_cancel" style="padding:4px 10px;border-radius:8px;border:2px solid var(--line);cursor:var(--jawnos-cursor-pointer, pointer);"></button>')
		.attr('data-id', a.id)
		.attr('hint', helpPendingT('Cancel this change'))
		.text(helpPendingT('Cancel'))
		.appendTo(row);
	return row;
}

function helpPendingRender(actions) {
	var el = helpPendingContainer();
	if (!el.length) { return; }
	el.empty();
	if (!actions || !actions.length) { el.hide(); return; }
	el.append($('<div style="font-size:11px;text-transform:uppercase;letter-spacing:.08em;opacity:.6;padding:0 0 4px;"></div>').text(helpPendingT('Waiting for your answer')));
	actions.forEach(function (a) { if (a && a.id) { el.append(helpPendingRow(a)); } });
	el.show();
}

function helpPendingLoad() {
	var el = helpPendingContainer();
	if (!el.length) { return; }
	$.get('/manager/help/pending', function (r) {
		helpPendingRender(r && r.actions ? r.actions : []);
	}).fail(function () { helpPendingHide(); });
}

function helpPendingReload() {
	var el = helpPendingContainer();
	if (el.length) { helpPendingLoad(); }
}

function helpPendingConfirm(id) {
	if (!id || jawnos_help_pending_busy) { return; }
	jawnos_help_pending_busy = true;
	$.ajax({
		url: '/manager/help/pending/confirm',
		type: 'POST',
		data: { id: id },
		success: function (r) {
			var text = (r && (r.observation || r.error)) ? String(r.observation || r.error) : '';
			if (text && typeof helpChatAdd === 'function') {
				helpChatAdd('guide', text);
				if (typeof helpShowChat === 'function') { helpShowChat(true); }
			}
			helpPendingLoad();
		},
		error: function () { helpPendingLoad(); },
		complete: function () { jawnos_help_pending_busy = false; }
	});
}

function helpPendingCancel(id) {
	if (!id || jawnos_help_pending_busy) { return; }
	jawnos_help_pending_busy = true;
	$.ajax({
		url: '/manager/help/pending/cancel',
		type: 'POST',
		data: { id: id },
		success: function () { helpPendingLoad(); },
		error: function () { helpPendingLoad(); },
		complete: function () { jawnos_help_pending_busy = false; }
	});
}

$(document).on('click', '.help_pending_confirm', function () {
	helpPendingConfirm($(this).attr('data-id') || '');
});
$(document).on('click', '.help_pending_cancel', function () {
	helpPendingCancel($(this).attr('data-id') || '');
});

$(document).ready(function () {
	if (helpPendingContainer().length) { helpPendingLoad(); }
});
