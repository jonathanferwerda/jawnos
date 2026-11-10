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

