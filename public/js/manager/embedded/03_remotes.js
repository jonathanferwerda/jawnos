// ---- learned IR remotes: learn, name, send, delete --------------------------
// The board captures a burst on its receiver pin and POSTs it to /watch/ir,
// which stores it as a pending entry on the board's own record. This panel
// polls that list for a few seconds after a learn, lets a person name the
// capture, then replays or deletes a named remote.

var embeddedIrRemotes = {};
var embeddedIrPollTimer = null;

function embeddedIrStatus(text, is_error) {
	var box = $('#embedded_ir_status');
	if (!box.length) { return; }
	box.text(text).css('color', is_error ? '#b00020' : '');
}

function embeddedIrChip() {
	var chip_id = embeddedChipId();
	if (!chip_id) {
		embeddedIrStatus(embeddedBoardText('Choose a board first.'), true);
	}
	return chip_id;
}

function embeddedIrRender(remotes) {
	var list = $('#embedded_ir_list').empty();
	var names = Object.keys(remotes || {}).sort();
	if (!names.length) {
		list.append($('<div class="embedded_ir_empty">').text(
			embeddedBoardText('No remotes learned yet.')));
		return;
	}
	for (var i = 0; i < names.length; i++) {
		var name = names[i];
		var entry = remotes[name] || {};
		var pin = (entry.pin != null) ? entry.pin : '?';
		var seq = (typeof entry.seq === 'string') ? entry.seq : '';
		var count = seq ? seq.split(',').length : 0;
		// The name is user text, so it rides an attribute and never an id.
		var row = $('<div class="embedded_ir_remote" style="margin:3px 0;font-size:16px;">')
			.attr('data-name', name)
			.attr('data-index', i)
			.attr('data-pending', entry.pending ? '1' : '0');
		row.append($('<span style="font-weight:700;margin-right:6px;">').text(name));
		row.append($('<span style="margin-right:6px;">').text(
			embeddedBoardText('GPIO') + ' ' + pin + ' — ' +
			count + ' ' + embeddedBoardText('transitions')));
		if (entry.pending) {
			row.append($('<input type="text" class="embedded_ir_name">')
				.attr('placeholder', embeddedBoardText('Name this remote'))
				.attr('aria-label', embeddedBoardText('Name this remote')));
			row.append(' ');
			row.append($('<button class="embedded_ir_save">').text(embeddedBoardText('Save')));
			row.append(' ');
		}
		row.append($('<button class="embedded_ir_send">').text(embeddedBoardText('Send')));
		row.append(' ');
		row.append($('<button class="embedded_ir_delete">').text(embeddedBoardText('Delete')));
		list.append(row);
	}
}

function embeddedIrLoad() {
	var chip_id = embeddedChipId();
	if (!chip_id) {
		$('#embedded_ir_list').empty();
		embeddedIrStatus(embeddedBoardText('Choose a board to see its remotes.'), true);
		return;
	}
	$.ajax({
		url: '/manager/embedded/remotes',
		type: 'GET',
		dataType: 'json',
		data: { edt: 'microcontroller', chip_id: chip_id }
	}).done(function(response) {
		if (!response || !response.ok) {
			embeddedIrStatus((response && response.error) ||
				embeddedBoardText('Could not read the remotes.'), true);
			return;
		}
		embeddedIrRemotes = response.remotes || {};
		embeddedIrRender(embeddedIrRemotes);
	}).fail(function(xhr) {
		embeddedIrStatus(embeddedBoardText('Could not read the remotes.') +
			' HTTP ' + xhr.status, true);
	});
}

// After a learn, the board captures and posts the burst on its own. Poll the
// list until a pending entry that was not there before appears, then stop.
function embeddedIrPoll(before, attempts, pin) {
	if (embeddedIrPollTimer) {
		clearTimeout(embeddedIrPollTimer);
		embeddedIrPollTimer = null;
	}
	if (attempts <= 0) {
		embeddedIrStatus(embeddedBoardText('Nothing arrived from the board.') + ' ' +
			embeddedBoardText('Press Learn again, then press a button on the remote.'), true);
		return;
	}
	embeddedIrPollTimer = setTimeout(function() {
		embeddedIrPollTimer = null;
		var chip_id = embeddedChipId();
		$.ajax({
			url: '/manager/embedded/remotes',
			type: 'GET',
			dataType: 'json',
			data: { edt: 'microcontroller', chip_id: chip_id }
		}).done(function(response) {
			if (response && response.ok) {
				var remotes = response.remotes || {};
				embeddedIrRemotes = remotes;
				embeddedIrRender(remotes);
				var names = Object.keys(remotes);
				for (var i = 0; i < names.length; i++) {
					var name = names[i];
					if (remotes[name] && remotes[name].pending &&
						before.indexOf(name) === -1) {
						embeddedIrStatus(embeddedBoardText('Learned a capture on GPIO') +
							' ' + pin + '. ' +
							embeddedBoardText('Name it, then press Save.'), false);
						$('#embedded_ir_list .embedded_ir_remote').filter(function() {
							return $(this).attr('data-name') === name;
						}).find('.embedded_ir_name').focus();
						return;
					}
				}
			}
			embeddedIrPoll(before, attempts - 1, pin);
		}).fail(function() {
			embeddedIrPoll(before, attempts - 1, pin);
		});
	}, 1000);
}

$(document).on('click', '#embedded_ir_refresh', function() {
	embeddedIrLoad();
});

$(document).on('click', '#embedded_ir_learn_button', function() {
	var button = $(this);
	var chip_id = embeddedIrChip();
	if (!chip_id) { return; }
	var pin = parseInt($('#embedded_ir_learn_pin').val(), 10);
	var ms = parseInt($('#embedded_ir_learn_ms').val(), 10);
	if (isNaN(pin) || pin < 0 || pin > 29) {
		embeddedIrStatus(embeddedBoardText('The receiver pin must be 0 to 29.'), true);
		return;
	}
	if (isNaN(ms) || ms < 500 || ms > 10000) {
		embeddedIrStatus(embeddedBoardText('The learn window must be 500 to 10000 ms.'), true);
		return;
	}
	var before = Object.keys(embeddedIrRemotes || {});
	button.prop('disabled', true);
	embeddedIrStatus(embeddedBoardText('Asking the board to listen on GPIO') + ' ' + pin + ' ' +
		embeddedBoardText('for') + ' ' + ms + ' ' + embeddedBoardText('ms') + '.', false);
	$.ajax({
		url: '/manager/embedded/remote_learn',
		type: 'POST',
		dataType: 'json',
		data: { edt: 'microcontroller', chip_id: chip_id, pin: pin, ms: ms }
	}).done(function(response) {
		button.prop('disabled', false);
		if (!response || !response.ok) {
			embeddedIrStatus((response && response.error) ||
				embeddedBoardText('Could not start the learn window.'), true);
			return;
		}
		if (!response.sent) {
			embeddedIrStatus(embeddedBoardText('The board did not answer.') + ' ' +
				embeddedBoardText('Check that it is connected.'), true);
			return;
		}
		embeddedIrStatus(embeddedBoardText('Listening on GPIO') + ' ' + pin + ' ' +
			embeddedBoardText('for') + ' ' + ms + ' ' + embeddedBoardText('ms') + '.', false);
		embeddedIrPoll(before, 12, pin);
	}).fail(function(xhr) {
		button.prop('disabled', false);
		embeddedIrStatus(embeddedBoardText('Could not start the learn window.') +
			' HTTP ' + xhr.status, true);
	});
});

$(document).on('click', '.embedded_ir_save', function() {
	var button = $(this);
	var row = button.closest('.embedded_ir_remote');
	var old_name = row.attr('data-name');
	var entry = embeddedIrRemotes[old_name] || {};
	var typed = $.trim(row.find('.embedded_ir_name').val() || '');
	if (!typed) {
		embeddedIrStatus(embeddedBoardText('Give the remote a name first.'), true);
		row.find('.embedded_ir_name').focus();
		return;
	}
	if (typed === old_name) {
		embeddedIrStatus(embeddedBoardText('That remote already has this name.'), true);
		return;
	}
	if (embeddedIrRemotes[typed]) {
		embeddedIrStatus(embeddedBoardText('A remote with that name already exists.'), true);
		return;
	}
	var chip_id = embeddedIrChip();
	if (!chip_id) { return; }
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/embedded/remote_save',
		type: 'POST',
		dataType: 'json',
		data: {
			edt: 'microcontroller',
			chip_id: chip_id,
			pin: entry.pin,
			seq: entry.seq,
			name: typed
		}
	}).done(function(response) {
		if (!response || !response.ok) {
			embeddedIrStatus((response && response.error) ||
				embeddedBoardText('Could not save the remote.'), true);
			button.prop('disabled', false);
			return;
		}
		// The capture is under the typed name now; drop the pending key it had.
		$.ajax({
			url: '/manager/embedded/remote_delete',
			type: 'POST',
			dataType: 'json',
			data: { edt: 'microcontroller', chip_id: chip_id, name: old_name }
		}).done(function(removed) {
			if (!removed || !removed.ok) {
				embeddedIrStatus(embeddedBoardText('Saved, but the pending capture could not be removed.'), true);
			}
			else {
				embeddedIrStatus(embeddedBoardText('Saved') + ' ' + typed + '.', false);
			}
			embeddedIrLoad();
		}).fail(function(xhr) {
			embeddedIrStatus(embeddedBoardText('Saved, but the pending capture could not be removed.') +
				' HTTP ' + xhr.status, true);
			embeddedIrLoad();
		});
	}).fail(function(xhr) {
		embeddedIrStatus(embeddedBoardText('Could not save the remote.') +
			' HTTP ' + xhr.status, true);
		button.prop('disabled', false);
	});
});

$(document).on('click', '.embedded_ir_send', function() {
	var button = $(this);
	var name = button.closest('.embedded_ir_remote').attr('data-name');
	var chip_id = embeddedIrChip();
	if (!chip_id) { return; }
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/embedded/remote_send',
		type: 'POST',
		dataType: 'json',
		data: { edt: 'microcontroller', chip_id: chip_id, name: name }
	}).done(function(response) {
		button.prop('disabled', false);
		if (!response || !response.ok) {
			embeddedIrStatus((response && response.error) ||
				embeddedBoardText('Could not send the remote.'), true);
			return;
		}
		if (!response.sent) {
			embeddedIrStatus(embeddedBoardText('Could not reach the board to send') +
				' ' + name + '.', true);
			return;
		}
		embeddedIrStatus(embeddedBoardText('Sent') + ' ' + name + '.', false);
	}).fail(function(xhr) {
		button.prop('disabled', false);
		embeddedIrStatus(embeddedBoardText('Could not send the remote.') +
			' HTTP ' + xhr.status, true);
	});
});

$(document).on('click', '.embedded_ir_delete', function() {
	var button = $(this);
	var name = button.closest('.embedded_ir_remote').attr('data-name');
	var chip_id = embeddedIrChip();
	if (!chip_id) { return; }
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/embedded/remote_delete',
		type: 'POST',
		dataType: 'json',
		data: { edt: 'microcontroller', chip_id: chip_id, name: name }
	}).done(function(response) {
		button.prop('disabled', false);
		if (!response || !response.ok) {
			embeddedIrStatus((response && response.error) ||
				embeddedBoardText('Could not delete the remote.'), true);
			return;
		}
		embeddedIrStatus(embeddedBoardText('Deleted') + ' ' + name + '.', false);
		embeddedIrLoad();
	}).fail(function(xhr) {
		button.prop('disabled', false);
		embeddedIrStatus(embeddedBoardText('Could not delete the remote.') +
			' HTTP ' + xhr.status, true);
	});
});

// The panel is injected with the Embedded page, so a document ready is too
// early. Mark the element as it is first seen and load the board's remotes once
// per render; a chip change re-renders the page and clears the mark.
function embeddedIrPanelInit() {
	var panel = $('#embedded_ir_panel');
	if (!panel.length || panel.attr('data-ir-ready')) { return; }
	panel.attr('data-ir-ready', '1');
	embeddedIrLoad();
}

$(document).ready(embeddedIrPanelInit);
if (window.MutationObserver) {
	new MutationObserver(embeddedIrPanelInit).observe(document.body || document.documentElement,
		{ childList: true, subtree: true });
}
