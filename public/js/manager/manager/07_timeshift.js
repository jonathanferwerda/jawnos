$(document).on('click', '#timeshift_viewer', function() {
	var time_machine = $('#timeshift_viewer').text() + ' ' + $('#time_machine').val();
	$('#time_machine').val(time_machine);
	localStorage.setItem('time_machine',time_machine);
});

// Back to the present: the now button and a double-click on the canvas both
// come through here. Any glide or pending flick is stopped first - it would
// write the time machine back the moment it landed and undo this.
function nowResetter() {
	cancelAnimationFrame(clothesLinePos['timelineSmoothScrolling']);
	clothesLinePos['timelineSmoothScrolling'] = undefined;
	if (clothesLinePos['fling']) {
		clearTimeout(clothesLinePos['fling']['settle']);
		clothesLinePos['fling'] = undefined;
	}
	// and stand the drag state down, or calculator() sees the view as just moved
	// and declines to fetch the present back
	clothesLinePos['moving'] = 0;
	clothesLinePos['lastBX'] = undefined;
	clothesLinePos['mouseDrag'] = 0;
	clothesLinePos['startMove'] = undefined;
	$('#time_machine').val('');
	$('#timeshift').val('');
	localStorage.setItem('timeshift', '0');
	localStorage.setItem('time_machine','');
	localStorage.setItem('timeshift', '');
	timestamp = Date.now();
	initializer();
	debrief_setter();
	calculator();
}

$(document).on('click','.now',function() {
	nowResetter();
});



var note_typing_timeout;
$(document).on('keyup', '.notes, .ago, .duration', function() {
	var i = $(this);
	var app = i.closest('.appointment');
	var appointment = app.attr('app');
	clearTimeout(note_typing_timeout);
	note_typing_timeout = setTimeout(function() {
		$.each(['notes','ago','duration'], function(io,v) {
			var input = app.find('.' + v);
			var typed = input.val();
			if (input.hasClass('text_editor') && input.hasClass(v)) {
				typed = input.html();
			}
			if (typed && typed != '' && typed != '<br>') {
				jawnosAppFieldSet(appointment, v, typed);
			}
			else {
				jawnosAppFieldRemove(appointment, v);
			}
			input.trigger('change');
			// a long note also goes to the server, so a crash or another device
			// keeps it; the ago and duration stay in this browser only
			if (v == 'notes' && typeof jawnosAppDraftSend === 'function') {
				jawnosAppDraftSend(appointment, typed);
			}
		});
	},200);
});

// A keypress in the duration field marks its value as the person's own length,
// not the client's remembered default. It rides the next press (see
// managerReset) so a live stop uses it instead of the length the row ran.
$(document).on('keyup', '.duration', function() {
	var appointment = $(this).closest('.appointment').attr('app');
	if ($(this).val()) { jawnosAppFieldSet(appointment, 'duration_typed', 'yes'); }
	else { jawnosAppFieldRemove(appointment, 'duration_typed'); }
});


$(document).on('focus, click', 'input.time', function() {
	$(this).addClass('editing');
});

// A time field that belongs to an app (the Travel window's Start and End) keeps
// the distance from now as well as the moment it resolved to. The moment would be
// stale the next time the app is opened days later; the distance still means what
// the person typed ("an hour ago"), so the app reads that one.
$(document).on('change, focusout', 'input.time', function() {
	var input = $(this);
	var time = input.val();
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/ago',
		type: 'GET',
		data: { ago: time },
		success: function(response) {
			input.attr('timestamp', response);
			input.removeClass('editing');
			if (input.attr('setting') && input.attr('app')) {
				settingSetter({'app': input.attr('app'), 'setting': input.attr('setting'), value: response });
				settingSetter({'app': input.attr('app'), 'setting': input.attr('setting') + '_ago', value: timestamp - response });
			}
		}
	});
});




$(document).on('dblclick', '#timeshift', function() {
	var e = $(this);
	var scope = e.val();
	e.val(0);
	localStorage.setItem('timeshift', 0);
	debrief_setter();
});

var timeshift_timeout;
$(document).on('input', '#timeshift', function() {
	var timeshift = $(this).val();
	localStorage.setItem('timeshift', timeshift);
	if ($('.appointment_details').is(':visible') ) {
		$('.appointment_details').each(function(i,v) { 
			$(v).closest('.appointment').find('.det').trigger('dblClick');
		});
	}
	debrief_setter();
	clearTimeout(timeshift_timeout);
	setTimeout(function() {
		calculator();
	},10);
});

$(document).on('change', '#timeshift_scope', function() {
	var timeshift = $(this).val();
	localStorage.setItem('timeshift_scope', timeshift);
	var scope = 12;
	if (timeshift == 'h' ||timeshift == 'm'||timeshift == 's') { scope = 60 }
	if (timeshift == 'y') { scope = 20 }
	$('#timeshift_max').attr('max', scope );
	debrief_setter();
});

$(document).on('change', '#scope', function () {
	var scope = $(this).val();
	localStorage.setItem('scope', scope);
	debrief_setter();
});

$(document).on('change', '#filter', function () { 
	var filter = $(this).val();
	localStorage.setItem('filter', filter);
	debrief_setter()
});

$(document).on('change', '#layout', function() {
	var layout = $(this).val();
	localStorage.setItem('layout', layout);
	debrief_setter();
});

$(document).on('change', '#projects', function() {
	var project = $(this).val();
	localStorage.setItem('project', project);
	debrief_setter();
});

$(document).on('change', '#accounts', function() {
	var account = $(this).val();
	localStorage.setItem('account',account);

	debrief_setter();
});
$(document).on('change', '#background_images', function() {
	var bgi = localStorage.getItem('background_images');
	if (bgi == 'on') {
		bgi = 'off';
	}
	else {
		bgi = 'on';
	}
	localStorage.setItem('background_images', bgi);
	debrief_setter();
});
$(document).on('change', '#background_images_opacity', function() {
	var bgi = $(this).val();
	localStorage.setItem('background_images_opacity', bgi);
	$('#background').css({ 'opacity': bgi });
	debrief_setter();
});

$(document).on('change', '#sorts', function() {
	var sorts = $(this).val();
	localStorage.setItem('sorts', sorts);
	debrief_setter();
});

$(document).on('click','#appt_view_toggle', function() {
	var view = $(this);
	if (sessionStorage.getItem('appt_view_toggle') == 'on') {
		sessionStorage.setItem('appt_view_toggle', 'off')
		localStorage.setItem('appt_view_toggle', 'off');
		view.css({ 'background-color': '' });
	}
	else {
		view.css({ 'background-color': 'green' });
		sessionStorage.setItem('appt_view_toggle', 'on');
		localStorage.setItem('appt_view_toggle', 'on');
	}

});
var appts = {};
var response = {};
function deloreanBringer() {
	var now = Date.now();
	var readable = moment(now).format();
	var appts = []
	$('.appointment').each(function(n,v) {
		var v = $(this);
		if (v.is(':visible')){ appts.push(v.attr('app')); }
	});
	
	var appointments = JSON.stringify(appts);
	if (appts.length == 0 || sessionStorage.getItem('appt_view_toggle') != 'on') {
		appointments = [];
	}
	var timeshift = localStorage.getItem('timeshift');
	var timeshift_scope = localStorage.getItem('timeshift_scope');
	timeshift = timeshift + timeshift_scope;
	var scope = localStorage.getItem('scope');
	var sorts = localStorage.getItem('sorts');
	var layout = localStorage.getItem('layout');
	var filter = localStorage.getItem('filter');
	var project = localStorage.getItem('project');
	var account = localStorage.getItem('account');
	var background_images = localStorage.getItem('background_images');
	var background_images_opacity = localStorage.getItem('background_images_opacity');
	var time_machine = localStorage.getItem('time_machine');
	var appt_view_toggle = sessionStorage.getItem('appt_view_toggle') || localStorage.getItem('appt_view_toggle');
	return { 
		timestamp: now, 
		readable: readable,
		appts: appointments,
		scope: scope,
		sorts: sorts,
		layout: layout,
		filter: filter,
		timeshift: timeshift,
		time_machine: time_machine,
		account: account,
		project: project,
		appt_view_toggle: appt_view_toggle,
		background_images: background_images,
		background_images_opacity: background_images_opacity,
		now: now
	};
}
// ---- the last view this browser drew ----------------------------------------
//
// A reload used to leave the canvas blank until the first appointment_viewer
// response: the page's markup carries only the window chrome and the canvas,
// so every load waited on the manager's render queue before it had a row to
// show. The last good payload is kept in the sealed windows store instead, and
// a reload paints it at once; the server's answer replaces it on the same tick
// it would have painted.
//
// It is only shown when it can honestly be shown. The inputs that change a
// payload are its signature; the age of a "now" view is a short TTL; a view
// whose centre is pinned is not aged at all, because its rows cannot have
// moved. See jawnosTimelineCacheEligible().
var JAWNOS_TIMELINE_CACHE_IDENTITY = 'timeline_view';
// The TTL is the view's own scope, not a fixed number: time_span('5m') puts the
// centre five minutes from the left edge, and the window the person sees is twice
// that. A view older than its own half has less than half of the current window
// in it, so a phone's 5m scope is held to five minutes and the laptop's 10m scope
// to ten. The floor keeps a very small scope from disabling the cache; the cap
// keeps an hour-long scope from painting an hour-old canvas. An anchored view is
// not aged at all: the time machine names a moment and a timeshift is a distance
// from the anchor, so the same inputs describe the same rows however long the
// page was away. The fresh response replaces either one within the poll.
var JAWNOS_TIMELINE_CACHE_TTL_FLOOR = 60000;
var JAWNOS_TIMELINE_CACHE_TTL_CAP = 600000;
// One view is all that is kept; a payload past this is not worth the write or
// the room. The ordinary timeline is tens of kilobytes and a full day a few
// hundred, so four megabytes is a view no desk should need to restore.
var JAWNOS_TIMELINE_CACHE_MAX_BYTES = 4000000;
// The poll may answer every second; the view only has to be on disk for the
// next reload, so a burst of answers writes the last one after it settles.
var JAWNOS_TIMELINE_CACHE_SAVE_WAIT = 2000;
var jawnosTimelineCachePainted = 0;
// a server answer has landed: nothing cached may paint over it
var jawnosTimelineCacheLive = 0;
var jawnosTimelineCacheSaveTimer;

// What makes two views the same view: every input that changes the payload, and
// nothing that changes with the clock (timestamp, now, readable) or that only
// decorates what the printers draw (the background images and their opacity).
// layout is in on purpose: the cache holds the last view of whichever layout it
// was last in, and a switch must not paint the old one's rows into the new one's
// canvas.
function jawnosTimelineCacheSignature(data) {
	data = data || {};
	var fields = ['scope', 'sorts', 'layout', 'filter', 'timeshift', 'time_machine', 'account', 'project', 'appt_view_toggle', 'appts'];
	var parts = [];
	for (var i = 0; i < fields.length; i++) {
		var value = data[fields[i]];
		if (value === undefined || value === null) { value = ''; }
		if (typeof value !== 'string') { value = JSON.stringify(value); }
		parts.push(fields[i] + '=' + value);
	}
	return parts.join('\n');
}

// A pinned centre cannot have moved while the page was away. "0s" and "in 0s"
// are the machine's way of saying now - graphicalize clears them - so they pin
// nothing. A timeshift is a distance from the anchor, so any non-zero one pins
// the view just as the machine does.
function jawnosTimelineCacheAnchored(data) {
	data = data || {};
	var machine = String(data['time_machine'] || '').replace(/^\s+|\s+$/g, '');
	if (machine && !/(^|\s)0s$/.test(machine)) { return true; }
	var shift = String(data['timeshift'] || '').replace(/^\s+|\s+$/g, '');
	var value = parseFloat(shift);
	return isFinite(value) && value !== 0;
}

// The view's own half-window: how long its scope reaches from the centre to the
// left edge. A 5m scope is 300000, a 10m one 600000; anything without a usable
// half falls back to the cap, which is the old ten-minute rule.
function jawnosTimelineCacheTTL(record) {
	var specs = record && record['view'] && record['view']['appts'] && record['view']['appts']['__specs'];
	if (specs) {
		var centre = Number(specs['timestamp']);
		var start = Number(specs['start']);
		if (isFinite(centre) && isFinite(start)) {
			var half = Math.abs(centre - start);
			if (isFinite(half) && half > 0) {
				return Math.min(Math.max(half, JAWNOS_TIMELINE_CACHE_TTL_FLOOR), JAWNOS_TIMELINE_CACHE_TTL_CAP);
			}
		}
	}
	return JAWNOS_TIMELINE_CACHE_TTL_CAP;
}

// The freshness rule in one place: a stored view paints only when the inputs
// still describe it (the signature), and then only if it is anchored - so its
// rows cannot have moved - or it is a now view younger than the short TTL.
// Anything else gets the ordinary skeleton and the fetch.
function jawnosTimelineCacheEligible(record, data, now) {
	if (!record || !record['view'] || !record['view']['appts'] || !record['view']['appts']['__specs']) { return false; }
	if (record['sig'] === undefined || record['sig'] !== jawnosTimelineCacheSignature(data)) { return false; }
	var fetched = Number(record['fetched_at']);
	if (!isFinite(fetched) || fetched <= 0) { return false; }
	if (jawnosTimelineCacheAnchored(data)) { return true; }
	var age = Number(now) - fetched;
	// a clock that stepped back must not make the cache look newer than the
	// page; treat it as just fetched rather than refusing it outright
	if (age < 0) { age = 0; }
	return age <= jawnosTimelineCacheTTL(record);
}

// A now view's specs name the moment it was fetched. The rows are placed from
// start to centre, so the old centre would put the whole view where it used to
// be; shift the specs by the time that has passed and let the drag path's own
// timelinePositions() recompute the percents. An anchored view keeps its specs:
// it is exactly where it was saved.
function jawnosTimelineCacheRecentre(view, now) {
	var specs = view && view['appts'] && view['appts']['__specs'];
	if (!specs) { return false; }
	var old = Number(specs['timestamp']);
	if (!isFinite(old) || !old) { return false; }
	var delta = Number(now) - old;
	if (!isFinite(delta)) { return false; }
	if (!delta) { return true; }
	var fields = ['timestamp', 'start', 'end', 'fetch_start'];
	for (var i = 0; i < fields.length; i++) {
		var value = Number(specs[fields[i]]);
		if (isFinite(value)) { specs[fields[i]] = value + delta; }
	}
	// server_time and stats are left alone on purpose: the stats short-circuit
	// reads server_time to decide whether the markers are fresh enough to ask
	// "anything new?", and moving it would claim the cache was newer than it is.
	return true;
}

// The layout printers are a lazy chunk; until one is reachable there is nothing
// to paint into. A stub installed by lazy.js counts - calling it loads the chunk
// and replays the print - so the chunk's ready callback may also call
// jawnosTimelineCachePaint() once its own file has run.
function jawnosTimelineCachePrinterReady(layout) {
	var printers = {
		timeline: 'timelinePrinter', calendar: 'calendarPrinter',
		leaderboard: 'leaderboardPrinter', clockface: 'clockfacePrinter',
		narrator: 'narratorPrinter', continent: 'continentPrinter'
	};
	var name = printers[layout];
	if (name && typeof window[name] !== 'function') { return false; }
	if (typeof graphicalize !== 'function') { return false; }
	if (typeof clotheslineHanger !== 'function') { return false; }
	return true;
}

// Paint the stored view if it is still the view. Safe to call any number of
// times: one attempt a page, never over a server answer, never under an open
// grant (the disk rule is private mode's, whatever the server rendered), and
// never for the desk, which draws neither timeline nor appointments. A private
// place is the safest place and keeps the view too.
function jawnosTimelineCachePaint(data) {
	if (jawnosTimelineCachePainted || jawnosTimelineCacheLive) { return false; }
	if (typeof jawnosWindowsGet !== 'function' || typeof jawnosWindowsPublicNow !== 'function') { return false; }
	if (!jawnosWindowsPublicNow(null, { allow_private_place: true })) { return false; }
	if (!data || typeof data !== 'object') {
		if (typeof deloreanBringer !== 'function') { return false; }
		data = deloreanBringer();
	}
	var layout = data['layout'] || localStorage.getItem('layout');
	if (!layout || layout == 'desk') { return false; }
	if (!jawnosTimelineCachePrinterReady(layout)) { return false; }
	// one attempt a page: a record that was not there will not appear later
	jawnosTimelineCachePainted = 1;
	jawnosWindowsGet(JAWNOS_TIMELINE_CACHE_IDENTITY).then(function(record) {
		// the fetch may have landed while the store was opening; its answer wins
		if (jawnosTimelineCacheLive) { return; }
		if (!jawnosTimelineCacheEligible(record, data, Date.now())) { return; }
		var view = record['view'];
		if (!jawnosTimelineCacheAnchored(data)) {
			if (!jawnosTimelineCacheRecentre(view, Date.now())) { return; }
			if (typeof timelinePositions == 'function') { timelinePositions(view['appts']); }
		}
		if (typeof graphicalize !== 'function') { return; }
		graphicalize({ appts: view['appts'], clothesline: view['clothesline'] || [] });
	}).then(null, function() {});
	return true;
}

// Keep the payload a fetch produced, for the next load. Debounced so the poll
// does not write every second, and refused where the store is refused already:
// the desk and an open private grant. A private place is the safest place and
// keeps the view; the open grant is the disk rule, even when the server's view
// itself excluded the private apps.
function jawnosTimelineCacheRemember(respons, data) {
	if (!respons || !respons['appts'] || !respons['appts']['__specs']) { return; }
	clearTimeout(jawnosTimelineCacheSaveTimer);
	jawnosTimelineCacheSaveTimer = setTimeout(function() {
		jawnosTimelineCacheSaveTimer = undefined;
		jawnosTimelineCacheWrite(respons, data);
	}, JAWNOS_TIMELINE_CACHE_SAVE_WAIT);
}

function jawnosTimelineCacheWrite(respons, data) {
	if (typeof jawnosWindowsSave !== 'function' || typeof jawnosWindowsPublicNow !== 'function') { return; }
	if (!jawnosWindowsPublicNow(null, { allow_private_place: true })) { return; }
	if (!data || !data['layout'] || data['layout'] == 'desk') { return; }
	var view = { appts: respons['appts'], clothesline: respons['clothesline'] || [] };
	var text;
	try { text = JSON.stringify(view); } catch (e) { return; }
	if (!text || text.length > JAWNOS_TIMELINE_CACHE_MAX_BYTES) { return; }
	// the store seals every value under the device key and hashes the identity;
	// this record is the same on-disk shape as a window shell
	jawnosWindowsSave(JAWNOS_TIMELINE_CACHE_IDENTITY, {
		view: view,
		sig: jawnosTimelineCacheSignature(data),
		fetched_at: Date.now()
	}).then(function() {
		// one view, but the store's own budget still decides when a desk's night
		// of shells has to give way
		if (typeof jawnosWindowsPrune === 'function') { jawnosWindowsPrune(); }
	});
}

function calculator() {
	var now = Date.now();

	// The desk has no appointment view to keep current: its clock runs on a
	// one-second tick of its own and its clothesline is read once a minute (both
	// in desk.js), so the whole appointment_viewer round trip is skipped.
	if (localStorage.getItem('layout') == 'desk') {
		if (typeof windowBackgroundAdjuster == 'function') { windowBackgroundAdjuster({ caller: 'calculator' }); }
		if (typeof deskShow == 'function') { deskShow(); }
		return;
	}

	if (!jawn_resting() && clothesLineAtRest()) {
		var data = deloreanBringer();
		windowBackgroundAdjuster({ caller: 'calculator' });
		// While the view is fresh, echo the markers of what we are showing so an
		// unchanged second can be answered "nothing new" - the server then skips the
		// whole per-app build. Past 35s (or before the first render) we send none,
		// which forces the full pass: the safety net against anything the markers
		// missed, and it is what resets the 35s clock.
		if (appts['__specs'] && appts['__specs']['stats'] && (now - 35000) <= appts['__specs']['server_time']) {
			data['stats'] = JSON.stringify({
				appts: appts['__specs']['stats']['appts'],
				settings: appts['__specs']['stats']['settings']
			});
		}

		// paint what was last drawn before asking, so the canvas is not empty while
		// the manager's render queue answers; the answer replaces it
		jawnosTimelineCachePaint(data);

		$.ajax({
			url:'/manager/appointment_viewer',
			type:'GET',
			data: data,
			success: function(respons){
				// A lapsed session - a stale cookie, or the cookieless first request a
				// webview sends as it wakes - is answered with the Gate page at HTTP 200,
				// not JSON. This handler used to trust it: appts became undefined and
				// response a string, so the poll threw and the pan (timelineScroller)
				// threw, freezing the timeline while the last-drawn hits still took taps.
				// Accept only a real reply. The full payload nests its specs as
				// respons.appts.__specs; the 'nothing new' short-circuit
				// ({ updateable: 'no', __specs: ... }) puts them at the top and carries no
				// appts. Either shape is real; the Gate page (a string) is not. Never
				// reload from here; the server answers a gated XHR with JSON 401 instead.
				if (!respons || typeof respons !== 'object'
					|| !(respons['__specs'] || (respons.appts && respons.appts['__specs']))) {
					return;
				}
				// whatever answer this is, the server has spoken for the view: a cached
				// paint arriving now would be older than it
				jawnosTimelineCacheLive = 1;
				if (respons.updateable != 'no') {
					if (clothesLineAtRest()) {
						appts = respons.appts;
					//	appts = { ...appts, ...response.appts };
						var pseudonyms = respons.pseudonyms;
						$('.time_jump').each(function(i,v) {
							$(v).attr('timestamp',respons.timestamp);
						});
						var ts = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');

						graphicalize(respons);
					//	inventoryDetailsUpdater();
						jawnosTimelineCacheRemember(respons, data);
					}
				}
				else {
					// nothing new was fetched: the view slides to the centre the server
					// names - exactly, and only from rest. The flick's ~32x reach belongs
					// to a gesture and not to a correction: added here it flew past the
					// target, and the next poll flew the whole error again, 32x larger,
					// until the dates left the calendar behind.
					if (clothesLineAtRest()) {
						timestamp = respons['__specs']['timestamp'];
						timelineScroller({ diff: (response.appts['__specs']['timestamp'] - respons['__specs']['timestamp']), source: 'slide' });
						response['__specs'] = respons['__specs'];
					}
				}
			}
		});
	}
}

$(document).on('click', '.web_toggle', function() {
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/web',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			windowMaker(response);
		}
	});


});

$(document).on('click', '.web', function() {
	var app = $(this).attr('app');
	var website = $(this).attr('web');
	var uuid = $(this).attr('uuid');
	var ts = timestamp;
	if (uuid) {
		ts = $(this).closest('.wind').attr('timestamp');
	}
	var user_agent =   navigator.userAgent; 
	$.ajax({
		url: '/manager/website_get',
		data: { app: app, website: website, timestamp: ts, user_agent: user_agent, uuid: uuid },
		success: function(response) {
			var ls = localStorage;
			var ss = sessionStorage;
			if (!uuid) {
			//	$('#browser').append(response.window);
				var window_id = windowMaker(response.window);
			}
			ts = $('.wind[app="web"]').attr('timestamp');
			uuid = response.uuid;
			$('#browser_' + ts).remove();
			$('<iframe>', {
				src: '/manager/browser?internal_url=' + response.internal_url + '&timestamp=' + ts + '&app=' + app + '&uuid=' + uuid,
				id:  'browser_' + ts,
				frameborder: 0,
				sandbox: 'allow-forms',
				scrolling: 'yes',
				style: "width:100%;height:calc(100% - 50px);position:absolute;top:90px;"
			}).appendTo('#window_contents_' + ts);
			$('#browser_' + ts).css({'background-color': 'white'}).addClass('web_browser_iframe').show();
			$('#website_title').text(response.app);
			$('#website_time').attr('timestamp', response.timestamp);
			$('#web').hide();
			$('#web_measure_toggle').attr('uuid', uuid).attr('app', app).show();
			appointment_chron();


			$('#browser_' + ts).on('load', function() {
				$(this).contents().find('body').on('mousemove', function(event) {
					var bs = $('#browser_' + ts);
					if (bs.hasClass('measure_selector_enabled')) {
						var selector = selectorMaker(event.target);
						var t = bs.find(selector).html();
					}
				});
				$(this).contents().find('body').on('click', function(event) {
					if ($('#browser_' + ts).hasClass('measure_selector_enabled')) {
						var selector = selectorMaker(event.target);
						if (!selector) {
							selector = $(event.target).prop('tagName').toLowerCase();
						}
						var text = $(event.target).text();
						// the selector can match many nodes; this says which one was clicked
						var index = $(this).find(selector).index(event.target);

						var measure = $('#web_measure_selector').val();
						$.ajax({ 
							url: '/manager/web/measure/set',
							type: 'post',
							data: { app: app, uuid: uuid, selector: selector, index: index, measure: measure, text: text },
							success: function(response) {
								jawnosAlert(response.confirmation);
							}
		
						});
					}
				});
			});
			var ls2 = localStorage;
			var ss2 = sessionStorage;
			$.each(ls2, function(i,v) {
				if (!ls[i]) {
					localStorage.removeItem(i);
					console.log('Removed ' + i);
				}
			});
			$.each(ss2, function(i,v) {
				if (!ss[i]) {
					sessionStorage.removeItem(i);
					console.log('Removed ' + i);
				}
			});
			if (!ls2['time_machine']) {
				localStorage.setItem('timestamp', '');
			}
			if (!ls2['timeshift']) {
				localStorage.setItem('timeshift', 0);
			}
		}
	});
});

$(document).on('click', '.web_measure_candidate', function() {
	$('.web_measure_candidate').removeClass('selected');
	$(this).addClass('selected');
	$(this).find('.web_measure_candidate_mark').html('&#9679;');
	$('.web_measure_candidate').not(this).find('.web_measure_candidate_mark').html('&#9675;');
});

$(document).on('click', '#web_measure_confirm_save', function() {

	var chosen = $('.web_measure_candidate.selected').first();
	if (!chosen.length) {
		return;
	}
	$.ajax({
		url: '/manager/web/measure/submit',
		type: 'POST',
		data: {
			app: chosen.attr('app'),
			measure: chosen.attr('measure'),
			spec: chosen.attr('spec')
		},
		success: function(response) {
			jawnosAlertClose();
		}
	});
});


$(document).on('click', '#web_measure_toggle', function() {
	var t = $(this);
	var app = t.attr('app');
	var uuid = t.attr('uuid');
	var tog = t.attr('toggle');
	var timestamp = $('#website_time').attr('timestamp');
	var wms = $('#web_measure_selector')
	wms.html('')
	wms.hide();
	if (tog == 'on') {
		tog = 'off';
		t.css({'background-color': ''});
		$('#window_content_' + timestamp).removeClass('web_measurable');
		$('.web_browser_iframe').removeClass('measure_selector_enabled');
	}
	else {
		tog = 'on';
		$.ajax({
			url: '/manager/web/measure/toggle',
			type: 'GET',
			data: { app: app, uuid: uuid },
			success: function(response) {
				t.css({'background-color': 'yellow'});
				$('#window_content_' + timestamp).addClass('web_measurable');
				var count = 0;

				$.each(response.measures, function(i,v) {
					var h = '<option value="' + i + '">' + v.formatted + '</option>';
					if (count == 0) {
						h = '<option selected value="' + i + '">' + v.formatted + '</option>';
					}
					$('#web_measure_selector').append(h).show();
					if (count == 0) {
						$('#web_measure_selector').val(i);
					}
					count++;
				});
				if (count > 0) {
					$('.web_browser_iframe').addClass('measure_selector_enabled');
				}

			}
		});
	}
	t.attr('toggle', tog);
});

