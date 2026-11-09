// ---- reading a board, then attaching a discovered pin ---------------------
// The manager asks the board itself over USB (or over its address when one is
// given) and answers with the parts it is configured for and the pins it can
// see. One press reads it; one more press attaches a discovered pin to an
// appointment through the same operator door the GPIO forms use.

function embeddedBoardText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function embeddedBoardAppName(app) {
	if (!app) { return embeddedBoardText('(no appointment)'); }
	return (typeof format_name === 'function') ? format_name(app) : app;
}

// A probe kind in the words a person uses for it, not the firmware's word.
function embeddedBoardKind(kind) {
	if (kind === 'grounded') { return embeddedBoardText('switched to ground'); }
	if (kind === 'high') { return embeddedBoardText('tied high'); }
	return embeddedBoardText('unclear');
}

// The appointments already wired on the page are the ones a person is likely
// to attach to. When the panel shows none, the row keeps a text box instead of
// an empty select.
function embeddedBoardAppointments() {
	var seen = {};
	$('.watch_component[app], .watch_input[app]').each(function() {
		var app = $(this).attr('app');
		if (app) { seen[app] = 1; }
	});
	return Object.keys(seen).sort();
}

function embeddedBoardComponentSelect(pin_kind, analog) {
	var select = $('<select class="embedded_board_component">');
	var choices = ['relay', 'led', 'servo', 'button', 'switch', 'pot'];
	var preferred = 'button';
	if (pin_kind === 'grounded') { preferred = 'button'; }
	else if (analog) { preferred = 'pot'; }
	else if (pin_kind === 'high') { preferred = 'switch'; }
	for (var i = 0; i < choices.length; i++) {
		var option = $('<option>').attr('value', choices[i])
			.text(embeddedBoardText(choices[i]));
		if (choices[i] === preferred) { option.attr('selected', 'selected'); }
		select.append(option);
	}
	return select;
}

function embeddedBoardAppPicker(apps) {
	if (!apps.length) {
		return $('<input type="text" class="embedded_board_app">')
			.attr('placeholder', embeddedBoardText('app name'));
	}
	var select = $('<select class="embedded_board_app">');
	select.append($('<option>').attr('value', '').text(embeddedBoardText('(no appointment)')));
	for (var i = 0; i < apps.length; i++) {
		select.append($('<option>').attr('value', apps[i]).text(embeddedBoardAppName(apps[i])));
	}
	return select;
}

function embeddedBoardRender(response) {
	var box = $('#embedded_board_pins').empty().show();
	if (!response || !response.ok) {
		box.append($('<div class="embedded_board_error">').text(
			embeddedBoardText('Could not read the board') + ': ' +
			((response && response.error) || embeddedBoardText('no answer'))));
		return;
	}
	var report = response.report || {};
	var components = report.components || [];
	var probe = report.probe || [];
	var chips = response.chip || report.chip || '?';
	var version = response.version || report.version || '?';
	var configured = (typeof response.components === 'number') ? response.components : components.length;
	var free = (typeof response.free === 'number') ? response.free : (report.free || []).length;
	var wired = 0;
	for (var i = 0; i < probe.length; i++) {
		if (probe[i] && probe[i].kind && probe[i].kind !== 'floating') { wired++; }
	}
	box.append($('<div class="embedded_board_summary" style="font-size:17px;margin-bottom:4px;">').text(
		chips + ' ' + embeddedBoardText('firmware') + ' ' + version + ' — ' +
		configured + ' ' + embeddedBoardText('configured') + ', ' +
		free + ' ' + embeddedBoardText('pins free') + ', ' +
		wired + ' ' + embeddedBoardText('looked wired')));

	var found = $('<div class="embedded_board_components" style="margin-bottom:6px;">');
	for (var c = 0; c < components.length; c++) {
		var comp = components[c] || {};
		var label = (comp.component || '?') + (comp.pin != null ? comp.pin : '') +
			' → ' + embeddedBoardAppName(comp.app);
		found.append($('<span class="embedded_detail">').text(label));
	}
	box.append(found);

	var apps = embeddedBoardAppointments();
	for (var p = 0; p < probe.length; p++) {
		var seen = probe[p] || {};
		if (!seen.kind || seen.kind === 'floating') { continue; }
		var row = $('<div class="embedded_board_probe" style="margin:3px 0;font-size:16px;">')
			.attr('pin', seen.pin);
		row.append($('<span style="font-weight:700;margin-right:6px;">').text(
			embeddedBoardText('GPIO') + ' ' + seen.pin));
		row.append($('<span style="margin-right:6px;">').text(embeddedBoardKind(seen.kind)));
		row.append(embeddedBoardAppPicker(apps));
		row.append(' ');
		row.append(embeddedBoardComponentSelect(seen.kind, seen.analog));
		row.append(' ');
		row.append($('<button class="embedded_board_attach">').text(embeddedBoardText('Attach')));
		box.append(row);
	}
}

$(document).on('click', '#embedded_board_read', function() {
	var button = $(this);
	var chip_id = embeddedChipId();
	var box = $('#embedded_board_pins').empty().show();
	box.append($('<div class="embedded_board_summary">').text(
		embeddedBoardText('Asking the board...')));
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/embedded/board_pins',
		type: 'GET',
		dataType: 'json',
		data: {
			chip_id: chip_id,
			edt: 'microcontroller'
		}
	}).done(function(response) {
		embeddedBoardRender(response);
	}).fail(function(xhr) {
		box.empty().append($('<div class="embedded_board_error">').text(
			embeddedBoardText('Could not read the board') + ': HTTP ' + xhr.status));
	}).always(function() {
		button.prop('disabled', false);
	});
});

$(document).on('click', '.embedded_board_attach', function() {
	var button = $(this);
	var row = button.closest('.embedded_board_probe');
	var chip_id = embeddedChipId();
	var pin = row.attr('pin');
	var app = row.find('.embedded_board_app').val() || '';
	var component = row.find('.embedded_board_component').val() || '';
	row.find('.embedded_board_error').remove();
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/embedded/board_pins_attach',
		type: 'POST',
		dataType: 'json',
		data: {
			edt: 'microcontroller',
			chip_id: chip_id,
			pin: pin,
			component: component,
			app: app,
			inverted: '',
			movement: ''
		}
	}).done(function(response) {
		if (response && response.ok) {
			var attached = response.attached || {};
			row.replaceWith($('<div class="embedded_board_attached" style="margin:3px 0;font-size:16px;">').text(
				embeddedBoardText('Attached') + ' ' + embeddedBoardText('GPIO') + ' ' + pin +
				' → ' + embeddedBoardAppName(attached.app || app) +
				' (' + (attached.component || component) + ')'));
			return;
		}
		row.append($('<div class="embedded_board_error">').text(
			(response && response.error) || embeddedBoardText('Attach failed')));
		button.prop('disabled', false);
	}).fail(function(xhr) {
		row.append($('<div class="embedded_board_error">').text(
			embeddedBoardText('Attach failed') + ': HTTP ' + xhr.status));
		button.prop('disabled', false);
	});
});
