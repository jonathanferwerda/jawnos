function openApps() {
	var apps = [];
	$('.appointment').each(function(i,v) {
		  apps.push($(v).attr('app'));
	});
	return apps;
}

$(document).on('click', '.top_navbar, .neighbour_window, .room_appt', function(e) {
	var clicker = $(this);
	var win = clicker.closest('.wind');
	var text = $(this).attr('app');
	if ($(e.target).closest('.navbar_buttons, .navbar_reveal').length) { return false; }
	if (typeof windowStacker === 'function' && typeof windowPhoneChecker === 'function'
		&& windowPhoneChecker() && clicker.hasClass('top_navbar')) {
		// a phone walks its pile on touchend, not here: a title bar that was just
		// dragged has its click swallowed by jQuery UI's drag, so the click cannot
		// be trusted to fire at all. Nothing to do on this one.
		return false;
	}

	var app = JSON.stringify({ name: text });
	var timestamp = Date.now();
	if (text == 'music' ) {
		var music_window = $('#music').closest('.wind').attr('id');
		topLevelNow($('#' + music_window));
	}
	else if (text == 'video') {
		var video_window = $('#video').closest('.wind').attr('id');
		topLevelNow($('#' + video_window));
	}
	else if ( text == 'gallery' ) {
		var wind = win.attr('id');
		topLevelNow($('#' + wind));
	}
	else if (text == 'marker') {
		var wind = $('#marker').closest('.wind').attr('id');
		topLevelNow($('#' + wind));
	}
	else if (text == 'mailbox') {
		var wind = $('#marker').closest('.wind').attr('id');
		topLevelNow($('#' + wind));
	}
	else if (text == 'terminal') {
		topLevelNow(win);
	}
	else {
		topLevelNow(win);
	}
	if ($('.wind[app="' + text +'"]').length == 0) {
		appointmentGrabber(text,Date.now());
	}

});

// A phone's title-bar tap walks the pile. It is taken on touchend, not click,
// because a window that was just dragged has its click swallowed by jQuery UI's
// drag state - the touch itself always fires, so the walk hangs off that.
$(document).on('touchend', '.top_navbar', function(e) {
	if (typeof windowPhoneChecker != 'function' || !windowPhoneChecker()) { return; }
	if ($(e.target).closest('.navbar_buttons, .navbar_reveal, .window_icon_holder').length) { return; }
	if (typeof windowStacker != 'function') { return; }
	windowStacker($(this).attr('app'));
});

// ---------------------------------------------------------------- app sections
//
// Two forms a window carries but does not show - the details (transaction) panel
// and the app's measures - are fetched the first time a control reveals them
// instead of being rendered into every open. A window is ~42 KB of HTML, and the
// details form alone was 11 KB of it for a form nobody had asked to see.
//
// The placeholder is replaced in place, so every selector that already looks for
// .app_details or .app_measure keeps working once the fetch lands; a second
// press finds the form already there.
function appSectionGrabber(app, section, container, done) {
	var scope = container && container.length ? $(container) : $('.appointment[app="' + app + '"]');
	var holder = scope.find('.app_section_placeholder[section="' + section + '"]').first();
	if (!holder.length) { if (done) { done(); } return; }
	if (holder.attr('loaded') == 'yes' || holder.attr('loading') == 'yes') { if (done) { done(); } return; }
	holder.attr('loading', 'yes');
	$.ajax({
		url: '/manager/app_section',
		type: 'GET',
		data: { app: app, section: section },
		success: function(response) {
			holder.removeAttr('loading');
			// an empty answer is a question worth asking again later, not a form
			if (response) { holder.attr('loaded', 'yes').html(response); }
			if (done) { done(); }
		},
		error: function() {
			// a failed fetch leaves the placeholder: the next press asks again
			holder.removeAttr('loading');
			if (done) { done(); }
		}
	});
}

$(document).on('click', '.reset', function() {
	var appointment = $(this).closest('.appointment');
	var app = appointment.attr('app');
	var details = appointment.find('.app_details');
	if (details.is(':visible')) {
		details.hide();
		appActSync(app);
	}
	else {
		appActExclusive(app, 'reset');
		// the form arrives hidden; showing it happens once it has landed
		appSectionGrabber(app, 'details', appointment, function() {
			appointment.find('.app_details').show();
			// the panel is only open once the form has landed, so the act frame
			// is sent from here, not from the click
			appActSync(app);
		});
	}

});

function projectAccountGrabber(details) {
	var container = details.closest('.appointment');
	var form = container.find('.app_details');
	former = form;
	var account = form.find('.account').val();
	var project = form.find('.project').val();
	var movement = form.find('.movement').val();
	var current_project = localStorage.getItem('project');

	if (current_project != 'all') {
		project = current_project;
	}
	return { account: account, project: project, movement: movement };
}

var appointmentLockingMechanism;
$(document).on('click', '.appointment_locking_mechanism', function() {
	var alm = $(this);
	var status = alm.attr('status');
	clearInterval(appointmentLockingMechanism);
	if (status == 'on') {
		alm.css({'background-color':'lightgrey'});
	}
	else {
		status = 'on';
		alm.css({'background-color':'red'});
		appointmentLockingMechanism = setTimeout(function() {
			alm.attr('status','off');
			alm.css({ 'background-color': 'lightgrey'});
		},4000);
	}
	alm.attr('status', status);
});

var former;
$(document).on('click', '.save_appointment', function(e) {
	managerReset($(this),e);
});


function managerReset(caller,e) {
	var lockingStatus = 'off';

	var details = caller;
	var pa = projectAccountGrabber(details);
	var app = details.attr('app');
	var container = details.closest('.appointment');
	var form = container.find('.app_details');
	former = form;
	if (container.find('.appointment_locking_mechanism').attr('status') == 'on' || e.ctrlKey == true) {
		lockingStatus = 'on';
	}
	var project = pa['project'];
	var movement = pa['movement'];

	var club = form.find('.club').val();
	var camera = details.attr('camera');
	var feed = details.attr('feed');
	var type = details.attr('type');
	// the media group's video/audio/screen buttons are record presses: the button
	// names the source, the row is a type=record like any other (so it moves
	// stock, stops, and edits the same way). A plain record press reads the
	// record row's machine too, so the dropdown governs every way of recording.
	var recorder = '';
	var media_group = details.attr('media_group') || '';
	if (media_group == 'record' && (type == 'video' || type == 'audio' || type == 'screen')) {
		recorder = type;
		type = 'record';
	}
	else if (!media_group && type == 'record') {
		media_group = 'record';
	}
	var media_machine = media_group ? container.find('.media_machine[group="' + media_group + '"]').first() : $();
	var remote_uuid = media_machine.length ? (media_machine.val() || '') : '';
	var remote_signatorial = media_machine.length ? (media_machine.find('option:selected').attr('data-signatorial') || '') : '';
	var digits = details.attr('digits');
	var item = form.find('.item').val();
	var amount = form.find('.amount').val();
	var ago = $('#ago').val() || container.find('.ago').val();
	var duration = container.find('.duration').val();
	// A duration the person typed is an account of this session; one the window
	// restored from an earlier visit is just the client's remembered field. The
	// stop may use the first and must not mistake the second for a length.
	var duration_typed = (duration && typeof jawnosAppFieldGet === 'function'
		&& jawnosAppFieldGet(app, 'duration_typed') === 'yes') ? 'yes' : 'no';
	var schedule = container.find('.schedule').val();
	var quantity = container.find('.main_input.quantity').val();
	var notes = container.find('.text_editor').html();
	var now = Date.now();
	// a stop names the session it closes: the appointment header carries the open
	// session's uuid, so the server stops that row on every machine and not
	// whichever open session each machine happens to hold (which left a stale one
	// behind to be swept up by the next stop)
	var running_uuid = '';
	if (type == 'stop') {
		running_uuid = container.find('.appointment_header_background').attr('running_uuid') || '';
	}
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	var warranty = container.find('.warranty').val();
	var navigation = container.attr('navigation');
	var measure_is_open = false;

	if (container.find('.re_measures').is(':visible')) {
		measure_is_open = true;
	}

	if (type == 'stop') {
		continent_cancel(app);
	}
	var data = { 
		app: app, 
		timestamp: now, 
		uuid: running_uuid,
		type: type, 
		ago: ago,
		duration: duration,
		duration_typed: duration_typed,
		warranty: warranty,
		project: project,
		amount: amount,
		item: item,
		notes: notes,
		time_machine: time_machine,
		timeshift: timeshift,
		camera: camera,
		feed: feed,
		remote_uuid: remote_uuid,
		remote_signatorial: remote_signatorial,
		recorder: recorder,
		digits: digits,
		schedule: schedule,
		movement: movement,
		measure_is_open: measure_is_open,
		quantity: quantity,
		lockingStatus: lockingStatus
	};
	$.ajax({
		url: '/manager/reset',
		type: 'POST',
		data: data,
		success: function(response) {
				appClearer(app)
				// The start/stop frame is also pushed over the websocket, but the
				// press that caused it must not depend on a live socket to show
				// the result: the reset returns the header it just rendered.
				if (response && response['header'] && typeof jawnosHeaderApply === 'function') {
					jawnosHeaderApply(app, response['header'], response['server_time']);
				}
				if (response && response.schedule_ask && typeof assistantAskFresh === 'function') {
					assistantAskFresh(app, response.schedule_ask);
				}
//			centreViewWriter(response);
		//	if ($('.now').attr('presence') != 'not') {

				if (type != 'start' && type != 'record' && navigation != 'resume') {
					navigation = 'once';
				}
				var diff = numeral(timestamp).value - numeral(now).value;
				diff = Math.abs(diff);
			//	if (diff < (1000 * 60)) {
					continent_record({'uuid':response['uuid'], 'app':response['app'],'purpose':'app','timestamp':response['timestamp'],'navigation':navigation});
			//	}
				calculator();
		//	}
		},
		error: function(error) { console.log(error) }
	});
}

function appClearer(app) {
	// the note has been filed on the appointment: the draft it grew from is done
	if (typeof jawnosAppDraftSend === 'function') { jawnosAppDraftSend(app, ''); }
	$('.appointment[app="' + app + '"]').each(function(i,v) {
		var container = $(v);
		jawnosAppFieldRemove(app, 'notes');
		jawnosAppFieldRemove(app, 'ago');
		jawnosAppFieldRemove(app, 'duration');
		jawnosAppFieldRemove(app, 'duration_typed');
		container.find('.ago').val('');
		container.find('.duration').val('');
		container.find('.schedule').val('');
		container.find('.text_editor').html('').trigger('change');
	});
	// the readings under ago and warranty belong to the moment the press just
	// wrote, so they are asked again rather than left on the old words
	if (typeof jawnosTimePreviewPaintApp === 'function') { jawnosTimePreviewPaintApp(app); }
}

// The bottom line is a row of headers with one panel open at a time. The
// evaluation comes with the window; the readings behind the other headers are
// fetched the first time one is pressed, so a window nobody reads them from pays
// nothing for them.
function appointmentStatsShow(stats, stat) {
	stats.find('.appointment_stats_header').each(function() {
		var chosen = ($(this).attr('stat') || '') === stat;
		$(this).toggleClass('selected', chosen).attr('aria-selected', chosen ? 'true' : 'false');
	});
	stats.find('.appointment_stats_panel').each(function() {
		$(this).toggle(($(this).attr('stat') || '') === stat);
	});
}

$(document).on('click', '.appointment_stats_header', function() {
	var header = $(this);
	var stats = header.closest('.appointment_stats');
	var stat = header.attr('stat') || '';
	var app = stats.attr('app') || '';
	if (stat !== 'evaluation' && !stats.find('.appointment_stats_panel[stat="' + stat + '"]').length) {
		// a second press while the first is in flight is remembered, so the panel
		// the person last asked for is the one that opens
		stats.attr('stats_wanted', stat);
		appSectionGrabber(app, 'stats', stats, function() {
			var wanted = stats.attr('stats_wanted') || stat;
			stats.removeAttr('stats_wanted');
			appointmentStatsShow(stats, wanted);
		});
		return;
	}
	appointmentStatsShow(stats, stat);
});

function centreViewWriter(response) { 
	// windowMaker decides for itself whether the app's window is already on the
	// page (it has the .wind nodes), so all this did was run windowMaker again
	// for every .appointment carrying the app - and the first call had already
	// replaced the window, so those repeats redrew the same thing. The cost was
	// a full jQuery parse of the response plus a jQuery wrap of every
	// .appointment on the page, hundreds on a busy desk. Parse once, as inert
	// DOM, and hand that same parse to windowMaker.
	windowMaker(response, windowResponseFragment(response));
	appointment_chron();
}


function appointmentGrabber(app,timestamp,source) {
	var waiter = 0;
	if (timestamp == '') {
		timestamp = jawnosWindowTimestamp();
	}
	if (source == 'onchange') {
		waiter = 500;
	}
	var jpR = jpReport(app);
	var appt = JSON.stringify({ app: app, name: app, source: 'grabber', jpReport: jpR });
	setTimeout(function() {
		$.ajax({ 
			url: '/manager/centre_view',
			type: 'GET',
			data: { app: appt, timestamp: timestamp, source: source },
			success: function(response) {
				centreViewWriter(response);
				jpRestore(app,jpR);
				var done = Date.now();
				console.log(app + ' ' + numeral(done - timestamp).value());
			}
		});
	},waiter);
}

var windows = [];

// ---------------------------------------------------------------- app back
// A launched single-app view (JawnAppActivity) asks this before leaving the
// app: the app's own view history answers first, so Back walks a Gallery photo
// to its album to the albums page instead of jumping straight to Home. An app
// with no handler falls through to the WebView's history and then the activity.
var jawnosBackHandlers = {};
function jawnosRegisterBack(app, handler) {
	if (app && typeof handler === 'function') { jawnosBackHandlers[app] = handler; }
}
function jawnosAppBack(app) {
	var handler = jawnosBackHandlers[app];
	if (typeof handler !== 'function') { return false; }
	try { return handler() === true; } catch (e) { return false; }
}
var top_level_now = 100;
var winLine = 0;
var fullXCount = 0;
var fullYCount = 0;


async function random_word(words) {
	var timestamp = Date.now();
	return await $.ajax({
		url: '/manager/random_word',
		type: 'GET',
		data: { 'times': words, 'timestamp': timestamp },
		success: function(response) {
			return response;

		}
	});
}

$(document).on('click', '.measures', function() {
	var a = $(this);
	var timestamp = Date.now();
	var parent = a.closest('.appointment');
	var app = parent.attr('app');
	var container = $('.appointment[app="' + app + '"]').find('.re_measures');
	if (container.is(':visible')) {
		container.hide();
	}
	else {
		appActExclusive(app, 'measures');
		appSectionGrabber(app, 'measures', parent);
		appointmentMeasuresGrabber(a);
		container.show();
	}
	appActSync(app);
});

$(document).on('touchmove mouseout hover keydown keyup touchend mousedown mouseup mousewheel', '.app_measure', function() {
	var mdm = $(this);
	var appt = mdm.closest('.appointment');
	var app = appt.attr('app');
	var value = mdm.val();
	var unit = mdm.attr('unit');
	var measure = mdm.attr('measure');
	appt.find('.app_measure_display[measure="' + measure + '"]').text(value + unit);


});

$(document).on('change keyup', '.app_measure', function() {
	var mdm = $(this);
	var appt = mdm.closest('.appointment');
	var app = appt.attr('app');
	var value = mdm.val();

	if (mdm.attr('multiple')) {
		value = JSON.stringify(value);
	}
	else if (mdm.attr('type') == 'checkbox') {
		if (mdm.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off';
		}
	}



	var measure = mdm.attr('measure');
	appt.find('.app_measure_display[measure="' + measure + '"]').text(value);
	mdm.attr('changed', 'yes');
	$.ajax({
		url: 'manager/app_measures',
		type: 'POST',
		data: { app: app, value: value, measure: measure, just_one: true, setting_only: 'yes', timestamp: timestamp },
		success: function(response) {
		}
	});
});


var amsave;
$(document).on('click', '.app_measure_save', function() {
	var mdm = $(this);
	var appt = mdm.closest('.appointment');
	var app = appt.attr('app');
	var container = mdm.closest('.appointment');
	var ago = $('#ago').val() || container.find('.ago').val();
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	appt.find('.app_measure[changed="yes"]').each(function(i,v) {

		var val = $(v).val();
		var measure = $(v).attr('measure');

		$.ajax({
			url: 'manager/app_measures',
			type: 'POST',
			data: { app: app, value: val, measure: measure, just_one: true, timestamp: timestamp, timeshift: timeshift, time_machine: time_machine, ago: ago },
			success: function(response) {
				$(v).attr('changed',undefined);
				mdm.addClass('superactive');
				clearTimeout(amsave);
				amsave = setTimeout(function() {
					mdm.removeClass('superactive');
				},1000);
				appClearer(app);
			}
		});
	});
});

$(document).on('click','.app_measure_delete', function() {
	var b = $(this);
	var app = b.closest('.appointment_detail').attr('app');
	var uuid = b.attr('uuid');
	var app_uuid = b.closest('.appointment_detail').attr('uuid');
	var armed = b.attr('armed');


	if (armed == 'yes') {
		b.addClass('superactive');
		$.ajax({
			url: '/manager/app_measure_delete',
			type: 'POST',
			data: { app: app, app_uuid: app_uuid, uuid: uuid },
			success:function(response) {

			}
		});
	}
	else {
		b.attr('armed', 'yes');
		var bgcolor = b.css('background-color');
		b.css({'background-color': 'red' });
		setTimeout(function() {
			b.css({'background-color': bgcolor });
			b.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click','.edit_app',function() {

	var edit = $(this);
	var uuid = edit.attr('uuid');
	var app = edit.attr('app');
	var timestamp = edit.attr('timestamp');
	var appointment = edit.closest('.appointment');
	var ea = $('.appointment_edit_area[uuid="' + uuid + '"][app="' + app + '"]');
	if (ea.is(':visible')) {
		ea.hide();
	}
	else {
		$.ajax({
			url: '/manager/edit_app',
			type: 'GET',
			data: { app: app, uuid: uuid, timestamp: timestamp },
			success: function(response) {
				ea.html(response).show();
			}
		});

	}

});
