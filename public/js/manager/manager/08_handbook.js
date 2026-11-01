$(document).on('click','.web_delete', function() {
	var b = $(this);
	var app = b.attr('app');
	var uuid = b.attr('uuid');
	var armed = b.attr('armed');


	if (armed == 'yes') {
		b.addClass('superactive');
		$.ajax({
			url: '/manager/web/delete',
			type: 'POST',
			data: { app: app, uuid: uuid },
			success:function(response) {
				$('.web_history[app="' + app + '"][uuid="' + uuid + '"]').remove();
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


var ap;
var clockInterval;

function graphicalize(respons) {
	var ts = Date.now();
	
	// never let a non-payload (the Gate page a lapsed session returns) become the
	// global the poll and the pan read from - see the guard in calculator()
	if (respons && (typeof respons !== 'object' || !respons.appts)) { return; }
	if (!respons) {
		respons = response;
	}
	else {
		// a full payload replaces the one in hand; what it actually covers is
		// what a drag reads to know whether the window it reached was fetched
		if (respons !== response && typeof timelineFetchedSet == 'function') { timelineFetchedSet(respons.appts); }
		response = respons;
	}
	// the rail's band is the configured height, unless the desk wears no rail at
	// all (then the printers below reserve nothing for it)
	clothesLineHeight = (clotheslineEnabled && respons.clothesline.length) ? clothesLineBaseHeight : 0;
	appts = respons.appts;

	timestamp = appts['__specs']['timestamp'];
	if ($('#' + localStorage.getItem('layout')).length == 0) {
		return;
	}
	// a row outside the drawn window is kept out to the fetched edge instead: the
	// server reaches a span past the left edge so a row just behind it can stick
	// there, and carries the row of a still-running appointment however old it
	// is, and those rows are the ones the left edge is holding on to
	var fetch_start = appts['__specs']['fetch_start'];
	if (fetch_start == undefined) { fetch_start = appts['__specs']['start']; }
	var view_start = appts['__specs']['start'];
	$.each(appts, function(i,v) {
		$.each(v['list'], function(am,way) {
			if (way != undefined) {
				// The reach carries two kinds of row from the left that must not be
				// pruned as the view slides: a still-running appointment's row (pure
				// presence - its start may be far older than the reach, and its band is
				// what the left edge holds on to) and one that stopped inside the view
				// (it comes in with the span it ran). fetch_start travels with the view
				// on a slide, but these rows are anchored in time, so the first unchanged
				// poll would otherwise drop the running appointment and delete it.
				var held = way['stop_timestamp']
					? (way['stop_timestamp'] >= view_start)
					: (way['type'] == 'start' || way['type'] == 'record');
				if (held || (way['timestamp'] && way['timestamp'] >= fetch_start && way['timestamp'] <= appts['__specs']['end'])) {
				}
				else {
					appts[i]['list'].splice(am, 1);
					if (appts[i]['list'].length == 0) {
						delete appts[i];
					}
				}
			}
		});

	});
	var diff = Math.abs(timestamp - ts);
	var nowb = $('.now');
	if (diff > 1100) {
		nowb.attr( 'presence', 'not' );
		nowb.css({'background-color': 'red' });
		if (ts != timestamp) {

			nowb.css({'background-color': 'orange' });
		}
	}
	else if (diff <= 1100 && diff >= 500) {
		nowb.css({'background-color': 'yellow' });
		nowb.attr('presence', 'delayed');
	}
	else {
		nowb.attr('presence', 'here');
		nowb.css({'background-color': 'green' });
	}
	var layout = localStorage.getItem('layout');
	var timeshit = localStorage.getItem('timeshift');
	var time_machine = localStorage.getItem('time_machine');
	var background_images = localStorage.getItem('background_images');

	if (time_machine == '0s' || time_machine == 'in 0s') {
		$('#time_machine').val('');
		localStorage.setItem('time_machine', '');
		time_machine = '';
	}
	// the tile carries the time machine's state itself now that the background
	// carries the server's speed (an older universal.js just keeps its icon)
	if (typeof nowIconApply == 'function') { nowIconApply(time_machine != '' ? 'time_machine' : 'here'); }

	//guests.push(appts);
	$.each(['leaderboard', 'clockface', 'timeline', 'calendar', 'continent', 'narrator', 'desk'], function(i,v) {
		if (v != layout)
			$('#' + v).hide();
	});
	if (layout == 'clockface'){
		clockfacePrinter(appts);
	}
	else if (layout == 'leaderboard') {
		leaderboardPrinter(appts);
	}
	else if (layout == 'calendar') {
		calendarPrinter(appts);
	}
	else if (layout == 'narrator') {
		narratorPrinter(appts);
	}
	else if (layout == 'timeline') {
		timelinePrinter(appts);
	}
	else if (layout == 'continent') {
		continentPrinter(appts);
	}
	// the desk is a wallpaper plus a layer of items, not a canvas printer; the
	// layer loads the listing the first time it is shown and after any change
	if (layout == 'desk') {
		if (typeof deskShow == 'function') { deskShow(); }
	}
	else if (typeof deskHide == 'function') {
		deskHide();
	}
	if (background_images == 'on') {
		backgroundPrinter(appts,respons);
	}
	else {
		$('#background').hide();
	}
	// The whole payload used to be stringified into sessionStorage here - every
	// app, every appointment, megabytes of it - so the two handlers that read it
	// could fall back on one number, the view's timestamp. That was over quota
	// and failing silently; the timestamp is what they get now.
	sessionStorage.setItem('appts_timestamp', appts['__specs']['timestamp']);

	clotheslineHanger(respons.clothesline);
	// the rail's band is only known once it has hung, so the desk's icons take
	// their place under it after it does
	if (layout == 'desk' && typeof deskPosition == 'function') { deskPosition(); }
}

var page_number = 0;
$(document).on('click', '#marker_toggle', function() {
	var timestamp = Date.now();
	var app = topWindow('marker');
	var url = '/manager/marker';
	if ($('#marker_toolbox').length > 0) {
		var mid = $('#marker_toolbox').closest('.wind').attr('id');
		$('#' + mid).show();
		topLevelNow($('#' + mid));
	}
	else {
		$.ajax({
			url: url,
			type: 'GET',
			data: { window_maker: 'yes', app: app, timestamp: timestamp, browser_tab_id: bti },
			success: function(response) {
				windowMaker(response);
				markerInit();
			}, error: function (response) {  }
		});
	}
});

$(document).on('click', '#terminal_toggle', function() {
	terminalOpener({ window_maker: 'yes' });
});

$(document).on('click', '#twirl_toggle', function() {
	twirlRunning = false;
	var url = '/manager/twirl';
	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response)
		}, error: function (response) {  }
	});
});



$(document).on('click', '#home_toggle', function() {
	var url = '/manager/home';

	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response);
		}, error: function (response) { }
	});
});

$(document).on('click', '#store_toggle', function() {
	storeOpener();
});

$(document).on('click', '#handbook_toggle', function() {

	var chapter = localStorage.getItem('handbook_chapter') || 'today';
	if (chapter == 'undefined' || chapter == 'null') { chapter = 'today'; }
	var url = '/manager/handbook/' + chapter;
	var page = localStorage.getItem('handbook_page');
	var window_saver = sessionStorage.getItem('window_storage');
	var open_windows = JSON.parse(window_saver) || {};
	var timestamp = Date.now();
	$.ajax({
		url: url,
		data: { page: page, windows: window_saver },
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response)
		}, error: function (response) { 
		}
	});
});

$(document).on('click', '.handbook_link', function() {
	var chapter = $(this).attr('chapter');
	var page = $(this).attr('page');
	var type = $(this).attr('type');
	handbookGrabber(chapter,page,type);
});

function handbookGrabber(chapter,page,type) {
	if (chapter) { localStorage.setItem('handbook_chapter', chapter); }
	if (page) { localStorage.setItem('handbook_page', page); }
	var url = '/manager/handbook/' + chapter;
	var window_saver = sessionStorage.getItem('window_storage');
	var open_windows = JSON.parse(window_saver) || {};
	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp, page: page, type: type, windows: window_saver },
		success: function(response) {
			windowMaker(response)
		}, error: function (response) { 
		}
	});
}

// --- Handbook: Today -------------------------------------------------------
// The daily page carries its own day in a `day` param. Typing is read by the
// same resolver the clock uses (today, yesterday, jul 16, 2025-10-21), and the
// whole window is re-rendered in place, so its size and place are kept.
function handbookTodayGo(day) {
	localStorage.setItem('handbook_chapter', 'today');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/handbook/today',
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp, day: day },
		success: function(response) {
			windowMaker(response);
		}
	});
}

$(document).on('click', '.handbook_today_arrow', function() {
	handbookTodayGo($(this).attr('day'));
});

$(document).on('click', '#handbook_today_reset', function() {
	handbookTodayGo('today');
});

$(document).on('focus', '#handbook_today_date', function() {
	try { this.select(); } catch (e) {}
});

$(document).on('keydown keypress keyup', '#handbook_today_date', function(e) {
	e.stopPropagation();
	if (e.type != 'keydown') { return; }
	if (e.keyCode == 13) {
		e.preventDefault();
		handbookTodayGo($(this).val() || 'today');
	}
});

$(document).on('click', '.handbook_today_open_app', function(e) {
	e.stopPropagation();
	// a duration chip in the row is a reading that turns on its own click, not a
	// way to open the appointment it sits beside
	if ($(e.target).closest('.jawnos_duration').length) { return; }
	var app = $(this).attr('app');
	if (app) { appointmentGrabber(app); }
});

$(document).on('click', '.handbook_today_budget', function() {
	if (typeof budgetInit == 'function') { budgetInit(); }
});

$(document).on('click', '.handbook_today_relational', function() {
	if (typeof relationalOpener == 'function') { relationalOpener(); }
});

$(document).on('click', '.handbook_today_people_open', function() {
	if (typeof peopleOpener == 'function') { peopleOpener(); }
});

// The journal writes into the notes store tagged for the Handbook. The Guide's
// plant action reads those entries and writes ideas/plans/dreams as appointments
// on their future days, so they appear when the daily page is turned to them.
function handbookTodayT(text, value) {
	if (typeof jawnosT == 'function') { return jawnosT.apply(null, arguments); }
	return (value === undefined) ? text : text.replace('{0}', value);
}

function handbookJournalStatus(text, is_error) {
	$('#handbook_today_journal_status').text(text || '').toggleClass('error', !!is_error);
}

function handbookJournalSave(reload) {
	var text = $('#handbook_today_journal_text').val();
	var day = $('#handbook_today_date').val() || 'today';
	if (!text || !text.replace(/\s/g, '')) {
		handbookJournalStatus(handbookTodayT('Write something first.'), true);
		return $.Deferred().resolve(false).promise();
	}
	handbookJournalStatus(handbookTodayT('Saving...'));
	return $.ajax({
		url: '/manager/handbook/journal',
		type: 'POST',
		data: { text: text, day: day },
		dataType: 'json'
	}).done(function(response) {
		if (response && response.ok) {
			handbookJournalStatus(handbookTodayT('Saved.'));
			$('#handbook_today_journal_text').val('');
			if (reload !== false) { handbookTodayGo(day); }
		}
		else { handbookJournalStatus((response && response.error) || handbookTodayT('Could not save.'), true); }
	}).fail(function() {
		handbookJournalStatus(handbookTodayT('Could not save.'), true);
	});
}

function handbookPlant() {
	var text = $('#handbook_today_journal_text').val() || '';
	var day = $('#handbook_today_date').val() || 'today';
	// save first, so the Guide reads the entry that was just typed; then plant
	if (text && text.replace(/\s/g, '')) {
		handbookJournalSave(false).done(function(response) {
			if (response && response.ok) { handbookPlantNow(day); }
		});
	}
	else { handbookPlantNow(day); }
}

function handbookPlantNow(day) {
	var button = $('#handbook_today_plant');
	button.prop('disabled', true);
	handbookJournalStatus(handbookTodayT('Reading the journal...'));
	$('#handbook_today_planted_result').empty();
	$.ajax({
		url: '/manager/handbook/plant',
		type: 'POST',
		data: { day: day },
		dataType: 'json',
		timeout: 180000
	}).done(function(response) {
		if (!response || !response.ok) {
			handbookJournalStatus((response && response.error) || handbookTodayT('The Guide could not read the journal.'), true);
			return;
		}
		var items = response.planted || [];
		if (!items.length) {
			handbookJournalStatus(response.skipped ? handbookTodayT('Nothing new was planted.') : handbookTodayT('Nothing pointed forward yet.'));
			return;
		}
		$('#handbook_today_journal_text').val('');
		handbookJournalStatus(handbookTodayT('Planted {0} entries.', items.length));
		var html = '<div class="handbook_today_planted_list"><b>' + handbookTodayT('Planted across time') + '</b><ul>';
		$.each(items, function(i, item) {
			var title = $('<div>').text(item.title || '').html();
			var kind = $('<div>').text(item.kind || '').html();
			var when = $('<div>').text(item.day || '').html();
			html += '<li><a href="#" class="handbook_today_planted_jump" day="' + when + '">' + title + '</a> <span class="handbook_today_planted_when">' + kind + ' &middot; ' + when + '</span></li>';
		});
		html += '</ul></div>';
		$('#handbook_today_planted_result').html(html);
	}).fail(function() {
		handbookJournalStatus(handbookTodayT('The Guide could not read the journal.'), true);
	}).always(function() {
		button.prop('disabled', false);
	});
}

$(document).on('click', '#handbook_today_journal_save', function() {
	handbookJournalSave(true);
});

$(document).on('click', '#handbook_today_plant', function() {
	handbookPlant();
});

$(document).on('click', '.handbook_today_planted_jump', function(e) {
	e.preventDefault();
	handbookTodayGo($(this).attr('day'));
});

$(document).on('click', '.handbook_setting', function() {
	var a = $(this);
	var app = a.attr('app');
	var setting = a.attr('setting');
	var value = a.attr('value');

	$.ajax({
		url: '/manager/handbook/settings',
		type: 'POST',
		data: { app: app, setting: setting, value: value },
		success: function(response) {
			a.attr('value', response[app]);
		}
	});


});

