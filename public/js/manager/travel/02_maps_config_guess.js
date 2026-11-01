$(document).on('click', '.delete_travel_map', function() {
	var a = $(this);
	var row = a.closest('.travel_maps_row');
	var uuid = row.attr('uuid');
	var app_uuid = row.attr('app_uuid');
	var app = row.attr('app');
	if (a.attr('armed') == 'yes') {
		var obg = a.attr('obg');
		a.css({'background-color': obg });

		$.ajax({
			url: '/manager/travel/delete_map',
			type: 'POST',
			data: { file_uuid: uuid, app_uuid: app_uuid, app: app },
			success: function(response) {
				travelToggle();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.attr('obg', bgcolor);
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');
		},2000);
	}
});

$(document).on('change', '.travel_provider', function() {
	var value = $(this).val();
	settingSetter({ 'app': 'travel', 'setting': 'map_provider', 'value': value });
	travelProviderFields();
	if (travelMap) { travelMap.setProvider(value, $('#travel_custom_url').val(), travelProviderKeys()); }
});

$(document).on('change', '#travel_custom_url', function() {
	var value = $(this).val();
	settingSetter({ 'app': 'travel', 'setting': 'map_custom_url', 'value': value });
	travelProviderFields();
	if (travelMap) { travelMap.setProvider($('.travel_provider').val() || 'none', value, travelProviderKeys()); }
});

$(document).on('click', '#travel_config_toggle', function() {

	var tc = $('#travel_config');
	var status = tc.attr('status');
	if (status == 'visible') {
		status = 'hidden';
		tc.hide();
	} else {
		status = 'visible';
		// the toolbar is a flex row; .show() would restore the default block display
		tc.css('display', 'flex');
	}
	tc.attr('status', status);
	settingSetter({ 'app': 'travel', 'setting': 'config_visible', 'value': status });
});

$(document).on('click', '.travel_now', function() {
	settingDeleter({ 'app': 'travel', 'setting': 'start_time' });
	settingDeleter({ 'app': 'travel', 'setting': 'end_time' });
	settingDeleter({ 'app': 'travel', 'setting': 'appt' });
	var settings = {
		start_time: null,
		end_time: null,
		appt: null
	};
	var timestamp = Date.now();
	travelViewer({ timestamp: timestamp, settings: settings });
});

// The hat is a toggle: with it on, the map asks the server to guess the empty
// ground in what you are looking at (the Plat models draw it, and every measured
// map is drawn over it, so it only shows where nothing is known); with it off,
// the blanks stay blank. A pause in the pan does the asking, and the guess lands
// framed where it lies.
var travelGuessBusy = 0;
var travelGuessAt = 0;
var travelGuessTimer = null;

// The status line is the guess's handle: it names the newest guess, and tapping
// it arms (turns red, as the trash buttons do) - a second tap drops that guess.
// A guess is a kept picture rather than a map in the picker, so this is the way
// a bad one goes; panning after it leaves the gap blank for a fresh guess.
function travelGuessStatus(text, uuid) {
	var status = $('#travel_guess_status');
	status.text(text || '');
	if (uuid) {
		status.attr('guess_uuid', uuid).addClass('hover').attr('hint', 'Last guess — tap twice to delete it');
	}
	else {
		status.removeAttr('guess_uuid').removeClass('hover').removeAttr('hint');
	}
}

$(document).on('click', '#travel_guess_status', function() {
	var t = $(this);
	var uuid = t.attr('guess_uuid');
	if (!uuid) { return; }
	if (t.attr('armed') == 'yes') {
		t.attr('armed', 'no').css('color', '');
		$.ajax({
			url: '/manager/travel/delete_map',
			type: 'POST',
			data: { file_uuid: uuid, app_uuid: '', app: 'travel' },
			success: function() {
				travelGuessStatus('');
				travelViewer({ timestamp: Date.now() });
			}
		});
	}
	else {
		t.attr('armed', 'yes').css('color', '#c62828');
		var was = t.text();
		t.text('tap again to delete this guess');
		setTimeout(function() {
			if (t.attr('armed') == 'yes') { t.attr('armed', 'no').css('color', '').text(was); }
		}, 2000);
	}
});

$(document).on('click', '#travel_guess_gap', function() {
	var t = $(this);
	var status = (t.attr('status') == 'enabled') ? 'disabled' : 'enabled';
	t.attr('status', status);
	t.css(status == 'enabled' ? { 'background-color': '#2e7d32', 'border-radius': '6px' } : { 'background-color': '', 'border-radius': '' });
	settingSetter({ 'app': 'travel', 'setting': 'guess_enabled', 'value': status });
	if (status == 'enabled') { travelGuessCheck('yes'); }
	else {
		travelGuessStatus('');
		travelViewer({ timestamp: Date.now() });
	}
});

function travelGuessCheck(force) {
	if (!travelMap || !window.jawnosMap) { return; }
	if ($('#travel_guess_gap').attr('status') != 'enabled') { return; }
	if (travelGuessBusy) { return; }
	var now = Date.now();
	if (!force && (now - travelGuessAt) < 20000) { return; }
	var b = travelMap.viewBounds();
	if (!b || !isFinite(b.nw.lat) || !isFinite(b.se.lat)) { return; }
	travelGuessBusy = 1;
	travelGuessAt = now;
	travelGuessStatus('looking for empty ground…');
	$.ajax({
		url: '/manager/travel/guess_gap',
		type: 'POST',
		data: { minLat: b.se.lat, maxLat: b.nw.lat, minLon: b.nw.lon, maxLon: b.se.lon, timestamp: now },
		success: function(response) {
			travelGuessBusy = 0;
			if (response && response['error']) { travelGuessStatus(response['error']); return; }
			if (response && response['covered']) { travelGuessStatus('all of this view is mapped'); return; }
			travelGuessStatus('guessed ' + response['name'], response['uuid']);
			travelPendingMap = response['uuid'];
			travelViewer({ timestamp: Date.now() });
		},
		error: function() {
			travelGuessBusy = 0;
			travelGuessStatus('the guess could not be made - see Configure, Plat');
		}
	});
}

$(document).on('change', '#travel_search', function() {
	var search = $(this).val();
	settingSetter({'app':'travel','setting':'search', 'value': search });
});

$(document).on('click', '.site_type_manual_changer_toggle', function() {
	if ($('.start_menu_main_display').is(':visible') && $('.site_type_manual_changer_options').length > 0) {
		console.log('showing');
		$('.start_menu_main_display').hide();
		$('.site_type_manual_changer_options').show();
	}
	else {
		console.log('hiding');
		$('.start_menu_main_display').show();
		$('.site_type_manual_changer_options').hide();
	}
});

$(document).on('click', '.site_type_manual_changer', function() {
	var site = $(this).attr('site');
	console.log(site);
	$.ajax({
		url: '/manager/configure/site_type/manual_change',
		type: 'POST',
		data: {
			site: site
		},
		success: function(response) {
			console.log(response);
			startMenuToggle({ source: 'updated' });
		}
	});
});