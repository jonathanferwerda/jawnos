var heartbeatSettle = {};
function stayingAlive(data) {
	var now = Date.now();

	if (!data || !data.app) { return; }
	if (ws[data.app]) { ws[data.app]['stayingAlive'] = now; }
	// A header a start or stop pushed can miss a tab that was reconnecting. The
	// beat names what this page is wearing; the server answers any newer one.
	if (data.headers && typeof jawnosHeaderApply === 'function') {
		var header_at = data.header_at || {};
		$.each(data.headers, function (app, html) {
			jawnosHeaderApply(app, html, header_at[app] || 0);
		});
	}
	// A slim beat is the server saying "still here; nothing on screen changed".
	// There is no neighbour list to rebuild and no pulse to paint.
	if (data.slim) { return; }
	var closer = $('.close_appointment[app="' + data.app + '"]');
	var neighbours = $('.neighbours[app="' + data.app + '"]');
	neighbours.find('.neighbour').each((i,n) => { n.remove() });
	clearTimeout(heartbeatSettle[data.app]);
	$('#controller_toggle').css({'transform': 'transform 0.25s ease scale(1.1)', '-webkit-transform':'scale(1.1)' });
	$('.heartbeating[app="' + data.app + '"]').css({'transform': 'transform 0.25s ease scale(1.1)', '-webkit-transform':'scale(1.1)' });
	// this was a 200ms interval that kept running until the next heartbeat (or
	// forever if heartbeats stopped) - a single timeout is all the pulse needs
	heartbeatSettle[data.app] = setTimeout(function() {
		$('#controller_toggle').css({'transform': 'transform 0.25s ease scale(1.0)', '-webkit-transform':'scale(1.0)' });
		$('.heartbeating[app="' + data.app + '"]').css({'transform': 'transform 0.25s ease scale(1.0)', '-webkit-transform':'scale(1.0)' });
	},250);
	data.neighbours = data.neighbours.sort((a, b) => a.browser_tab_id.localeCompare(b.browser_tab_id));
	if ($('#controller').is(':visible')) {
		$.each(data.neighbours, function(i,n) {

			var neighbour = neighbours.find('.neighbour[browser_tab_id="' + n['browser_tab_id'] + '"]');
			if (neighbour.length > 0) {
				var neighbour_check = $.grep(data.neighbours, function(t,it) { return n.browser_tab_id == t.browser_tab_id });

				if (neighbour_check.length != 0 ) { 
					// remove
					$.each(neighbour, function(u,m) { $('.neighbour[browser_tab_id="' + n.browser_tab_id + '"').remove() }); 
				}
				else {
					var neighbour = neighbours.find('.neighbour[browser_tab_id="' + n['browser_tab_id'] + '"]');
					$.each(neighbour,function(i,v) { 
						$(v).css({'background-color': 'green'}); 
					});
				}

			}
			else {
				var windows = JSON.parse(n.windows) ? JSON.parse(n.windows) : {};
				var neighbour_windows = '';
				$('#musicData').html('');
				if (data['app'] == 'tab') {
					neighbour_windows += '<img class="little_thumb neighbour_link" bti="' + n.browser_tab_id + '" src="/images/make believe/clover.png">';
					neighbour_windows += '<img class="little_thumb neighbour_refresh" bti="' + n.browser_tab_id + '" src="/icons/lymeboard/star.png">';

					$.each(windows, function(item,value) {
						if (value.type == 'window') {
							neighbour_windows += ' <button onClick="appointmentGrabber(\'' + value['app'] + '\',\'' + now + '\')" class="neighbour_window" style="border: solid; border-radius:12px; font-size:21px; padding-top:2px;" app="' + 
								item + '" shorthand="' + value['shorthand_name'] + '" formatted_name="' + value['formatted_name'] + '">' + value['shorthand_name'] + 
								'</button>';
						}
						$('#musicData').append(value['shorthand_name']);
					});
					neighbours.append('<span style="word-break:break-word;" browser_tab_id="' + n.browser_tab_id + '" local_address="' + n.local_address + '"' +
						'remote_address="' + n.remote_address + '" class="neighbour"  style="height: 30px; overflow:scroll;" >' +
						'<div><b>' + n.room +'<b></div><br>' + n.pathname + '<br><i>' + n.remote_address + '</i> on ' + n.local_address + '<br><b>' + n.user_agent + '</b><br>' +
						'<span class="neighbour_windows">' + neighbour_windows + '</span></span>'
					);
				}

				else if (data['app'] == 'music') {

					if ( n.music_data != undefined) {
						var md = JSON.parse(n.music_data) ? JSON.parse(n.music_data) : {};
						var height = 200;
						var width = height * md.title.ratio;
						var vidya = '';
						if (md.title.image) {
							vidya = '<img class="video_preview" width="' + width + '" height="' + height + '" style="border:2px;border-radius:12px;" file="' + md.file + '" current_time="' + md.current_time + '" src="' + md.title.image + '">';
						}
						var volume = 1;
						if (md.interface) {
							volume = $(md.interface).find('#music_volume').val();
						}
						neighbours.append('<span style="" class="neighbour" browser_tab_id="' + n.browser_tab_id + '">' +
						'<br><span class="media_controls">' + 
						'<img class="little_thumb remote_media_control" control="prev" browser_tab_id="' + n.browser_tab_id + '" src="/icons/prev.jpg">' +
						'<img class="little_thumb remote_media_control" control="play" browser_tab_id="' + n.browser_tab_id + '" src="/icons/play.jpg">' +
						'<img class="little_thumb remote_media_control" control="next" browser_tab_id="' + n.browser_tab_id + '" src="/icons/next.jpg"><br>' + vidya + '<br>' +
							'<progress style="width:100%;height:30px;" value="' + md.currentTime + '" control="progress_bar" class="remote_media_control" data-label="Progress" max="' + md.total_time + '"></progress><br>' +
							'<progress style="width:100%;height:30px;" class="remote_media_control" control="volume_control" value="' + volume + '" data-label="Volume"></progress>' +
							'</span><br>' +
							md.title.artist + '<br>' + md.title.album + '<br>' + md.title.song + '<br>' + 
							numeral(md.currentTime).format('00:00:00') + '/' + numeral(Math.abs(md.total_time)).format('00:00:00') + 
							'<br><div class="track_item_preview" style="display:none;">' + md.title.playing + '</div></span>'
						);
					}
				}
				else if (data['app'] == 'server') {
					var jd = JSON.parse(n.jp_data) ? JSON.parse(n.jp_data) : {};
					$.each(jd, function(ji,jv) {
						var height = 200;
						var width = height * jd.ratio;
						neighbours.append('<span class="neighbour" browser_tab_id="' + n.browser_tab_id + '"><br>' +
							'<img class="jp_preview video_preview" style="border:2px;border-radius:12px;" height="' + height + '" width="' + width + '" src="' + jv.image + '">' +
							'</span>'
						);
					});
					if (data['template']) { 
						if (data['template'] != $('.server_neighbour[browser_tab_id="' + n.browser_tab_id + '"]').html() ) {
							neighbours.append(data['template']); 
						}
					}

				}
				else if (data['app'] == 'mail') {
					neihbbours.append('mail');
				}
				else {
					var everything = [];
					var seen = 0;
					$('#everything_socket').find('button').each(function(i,v) {
						if ($(v).attr('app') == data.app) {
							seen = 1;
						}
					});
					if (data['template']) {
						if (seen == 0) {
							$('#everything_socket').append('<span style="" status="active" app="' + data.app + '" class="everything_neighbour neighbour">' + 
								data['template'] + 
								'</span><br><button onClick="appointmentGrabber(\'' + data.app + '\',\'' + now + '\')" class="heartbeating everything" timestamp="' + now + '" app="' + data.app + '">' + format_name(data.app) + '</button>'
							);
						}
						else if (seen == 1) {
							$('#everything_socket').find('.heartbeating.everything[app="' + data.app + '"]').attr('timestamp', now);
							$('#everything_socket').find('.everything_neighbour[app="' + data.app + '"]').html(data['template']);
						}
					}
					else {
						if (seen == 0) {
							$('#everything_socket').append('<button onClick="appointmentGrabber(\'' + data.app + '\',\'' + now + '\')" class="heartbeating everything" timestamp="' + now + '" app="' + data.app + '">' + format_name(data.app) + '</button>');
						}
						else if (seen == 1) {
							$('#everything_socket').find('.heartbeating.everything[app="' + data.app + '"]').attr('timestamp', now);
						}
					}
				}
			}
		});

		// No per-app interval here: the pulse is one 250ms settle, and stale
		// buttons are pruned on each full (non-slim) beat below.
		$('.heartbeating').each(function(i,v) {
			if ($(v).attr('timestamp') < ( now - stayingAliveInterval * 7) ) {
				$(v).remove();
			}
		});
	}
}


$(document).on('click', '.remote_media_control', function(e) {
	var control = $(this).attr('control');
	var destination = $(this).attr('browser_tab_id');
	var value = $(this).val();
	if ($(this).is('progress')) {
		 var total_width = $(this).width();
	  var current_location = e.offsetX;
	  value = (current_location / total_width);
	}
	var data = {
		app: 'music',
		control: control,
		destination: destination,
		value: value,
		type: 'remote_control'
	};
	$.ajax({
		url: 'manager/ws/remote_control',
		type: 'POST',
		data: data,
		success: function(response) {
			$(this).css({'transform': 'transform 0.25s ease scale(1.1)', '-webkit-transform':'scale(1.1)' });
			setTimeout(function() {
				$(this).css({'transform': 'transform 0.25s ease scale(1.0)', '-webkit-transform':'scale(1.0)' });
			},300);
		}
	});
});

$(document).on('click', '.neighbour_link', function() {
	var l = $(this);
	var browser_tab_id = l.attr('bti');
	var status = 'off';
	if (l.hasClass('active')) {
		l.removeClass('active');
	}
	else {
		l.addClass('active');
	}
});


$(document).on('click', '.neighbour_publish', function() {
	var ip = $(this).attr('ip');
	var uuid = $(this).attr('uuid');
	var browser_tab_id = $(this).attr('browser_tab_id');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/magazine/neighbour_publish',
		data: { ip: ip, timestamp: timestamp, browser_tab_id: browser_tab_id, uuid: uuid },
		success: function(response) {
			if (response == 'success') {
				$('#websocket_list').css({ 'background-color': 'green' });
				setTimeout(function() {
					$('#websocket_list').css({ 'background-color': 'yellow' });
				},2000);
			}
		}
	});
});

$(document).on('click', '.neighbour_status', function() {
	var s = $(this);
	var status = s.attr('status');
	var timestamp = Date.now();
	var ip = s.attr('ip');
	$.ajax({
		url: '/manager/neighbour_status',
		type: 'POST',
		data: { timestamp: timestamp, status: status, ip: ip },
		success: function(response) {
			s.attr('status', response['status']);			
		}
	});
});

$(document).on('click', '.video_preview', function() {
	var preview = $(this);
	if (tree.sound.playing != undefined) {
		tree.sound.currentTime = preview.attr('current_time');
	}
	else {
		mediaMaker({ file: preview.attr('file'), currentTime: preview.attr('current_time') });
		var track_preview = preview.closest('.neighbour').find('.track_item_preview').html();
		$('#files').prepend(track_preview);
	}

});

function websocketStop(app) {
	var timestamp = Date.now();
	var closer = $('.close_appointment[app="' + app + '"]');
	var browser_tab_id = sessionStorage.getItem('browser_tab_id');

	if (app && ws[app]) {
		if ( ws[app] ) { ws[app].close(); ws[app] = null;	delete ws[app]; };
		clearInterval(heartbeat[app]);

		$.each(ws, function(i,v) {
			if (i.match(app + '@')) {
				ws[i].close(); ws[i] = null;	delete ws[i];
			}
		});
		//closer.trigger('click');
		closer.css({'background-color':'red'});
	}
	else if (!ws[app] && app) {
		$.ajax({
			url: '/manager/ws_close',
			type: 'GET',
			data: { 
				browser_tab_id: browser_tab_id,
				app: app,
				timestamp: timestamp
			},
			success: function(response) {
				
			},
			error: function(err) {console.log('Error:', err) }
		});
	}
	else if (!app) {
		$.each(ws, function(i,v) {
			if (i != 'tab' || i != 'music' || i != 'server') {
				closer = $('.close_appointment[app="' + i + '"]');
				if (ws[i] != null) { ws[i].close(); }
				ws[i] = null;
				delete ws[i];
				clearInterval(heartbeat[app]);
				//closer.trigger('click');
			}
		});

	}
	delete heartbeat[app]; 
	if (windowVisible == 1) {
		websocketStart();
	}
}

function lockScreen() {
	// The screen going away closes the app padlocks with it. The grant is
	// dropped on the server for this screen alone and the visible content is
	// cleared at once; coming back redraws the locked view.
	if (typeof jawnosMediaLockdown === 'function') { jawnosMediaLockdown('', true); }
	if (typeof jawnosMediaLockBeacon === 'function') { jawnosMediaLockBeacon(''); }
}
function unlockScreen() {
	// The screen is back: draw what the server now says (locked, unless a fresh
	// print was given while it was away). The lock itself was sent when the
	// screen went away; sending it again would reach the other windows too.
	if (window.jawnosMediaLockPending && typeof jawnosMediaRefresh === 'function') {
		var apps = window.jawnosMediaLockPending;
		window.jawnosMediaLockPending = null;
		jawnosMediaRefresh(apps);
	}
	// A screen coming back is also a coming-to-front signal: rebuild the sockets
	// now instead of leaving a socket that slept to the next scheduled beat.
	if (typeof websocketFront === 'function') { websocketFront(); }
}


document.addEventListener("visibilitychange", function(e) {
	if (document.hidden) {
		lockScreen();
		$('#search').val('');
	}
	else {
		unlockScreen();
	}
});

// ---- following a code change without throwing the page away -------------------
// The server stamps the running code with a fingerprint, grouped part by part
// (subs::code_revision), and sends it on every socket connect. When it moved
// since this tab loaded, the quietest correct response depends on WHAT moved:
//
//   css   - point every stylesheet link at the new build; the browser re-fetches
//           a changed href, so a restyle lands live
//   views - re-render the open windows from the server, in place (wire it the
//   server  same: a Perl or template change shows when a window re-draws)
//   js    - cannot be swapped under a running page: the bundle is one classic
//   shell   concatenated script, and running it again would double every handler
//           it binds. These ask for one reload instead, quietly: at once when
//           the tab is hidden, otherwise with a small press-to-update pill. A
//           chat left in a coding agent survives the reload (coding.js saves it).

function jawnosRevisionArrived(parts, version, was) {
	var stored = null;
	try { stored = JSON.parse(sessionStorage.getItem('jawnos_revision_parts') || 'null'); } catch (e) { stored = null; }
	var remember = function () {
		if (parts) { sessionStorage.setItem('jawnos_revision_parts', JSON.stringify(parts)); }
		if (version) { sessionStorage.setItem('jawnos_version', version); }
	};
	// the first sight of a revision for this tab: nothing to follow yet, but a
	// tab that never recorded the parts may still have loaded an older build.
	// Its own version is in the page; when the house has moved on, one reload
	// is what puts the current JS and templates in front of the person.
	if (!was || !parts || !stored || !stored.js) {
		var page_version = (typeof jawnos_version !== 'undefined') ? String(jawnos_version) : '';
		if (version && page_version && String(version) !== page_version) { jawnosUpdateQuietReload(); return; }
		remember(); return;
	}
	var moved = function (k) { return (parts[k] || '') !== (stored[k] || ''); };
	var what = { js: moved('js'), shell: moved('shell'), css: moved('css'), views: moved('views'), server: moved('server') };
	remember();
	if (what.js || what.shell) { jawnosUpdateQuietReload(); return; }
	if (what.css || what.views || what.server) { jawnosUpdateInPlace(version, what); }
}

// The stylesheet links and the record of each script tag point at the new build;
// the windows re-render themselves. Nothing here reloads the page.
function jawnosUpdateInPlace(version, what) {
	// the Configure bar carries the number, so it moves with the code it names
	if (version && typeof jawnosConfigureVersion === 'function') { jawnosConfigureVersion(version); }
	if (version) {
		var bust = function (sel, attr) {
			$(sel).each(function () {
				var url = String($(this).attr(attr) || '');
				if (url.indexOf('string=') < 0) { return; }
				$(this).attr(attr, url.replace(/([?&]string=)[^&]*/, '$1' + encodeURIComponent(version)));
			});
		};
		bust('link[rel="stylesheet"]', 'href');
		// a script element that has already run does not re-run on a new src; this
		// keeps the page's own record honest for whatever reads it next
		bust('script[src]', 'src');
	}
	if (what.views || what.server || what.css) { jawnosUpdateWindows(); }
	jawnosUpdateNote('updated live');
}

// Apps whose openers do more than re-render (they bring a socket, a second
// session or a viewer with them). They keep their running window and pick the
// new build up the next time they open; everything else re-draws in place.
var jawnos_update_bespoke = { gallery: 1, help: 1, handbook: 1, embedded: 1, mailbox: 1, box_office: 1, store: 1, warehouse: 1, market: 1, measures: 1, budget: 1, studio: 1, terminal: 1, folders: 1, process_monitor: 1, music: 1, twirl: 1, cards: 1, marker: 1, editor: 1, synth: 1, ide: 1, relational: 1, travel: 1 };

function jawnosUpdateWindows() {
	var active = document.activeElement;
	var busy = active ? $(active).closest('.wind')[0] : null;
	$('.wind[app]').each(function () {
		var app = $(this).attr('app');
		// never yank the window someone is typing in, and leave the bespoke ones be
		if (!app || this === busy || jawnos_update_bespoke[app]) { return; }
		if (typeof jawnos_builtin_apps !== 'undefined' && !jawnos_builtin_apps[app]) { return; }
		if (typeof appWindowOpener === 'function') { appWindowOpener(app, Date.now(), { visible: 'yes' }); }
	});
}

// A transient line, the same corner the reload pill uses.
function jawnosUpdateNote(text) {
	if (!$('#jawnos_update_note').length) {
		$('body').append('<div id="jawnos_update_note" style="position:fixed;left:12px;bottom:12px;z-index:2147483000;background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:5px 10px;font-size:12px;opacity:0;transition:opacity .25s ease;box-shadow:0 4px 14px rgba(0,0,0,.25);pointer-events:none;"></div>');
	}
	var note = $('#jawnos_update_note');
	note.text(text).css('opacity', .92);
	clearTimeout(window.jawnos_update_note_timer);
	window.jawnos_update_note_timer = setTimeout(function () { note.css('opacity', 0); }, 2600);
}

// A script (or the shell) changed: one reload is the only safe answer, so ask
// for it - never over someone's typing, and never when they are not looking.
function jawnosUpdateQuietReload() {
	var save = function () { if (typeof jawnosCodingChatSave === 'function') { jawnosCodingChatSave(); } };
	save();
	if (document.hidden) { jawnosReloadWhenReady(); return; }
	if ($('#jawnos_update_pill').length) { return; }
	// a real button, not a text block: on a phone Chrome reads plain text as
	// something to touch-and-search, and a tap on "update" offered a web search.
	// A button with no selectable text is only ever a thing to press.
	var pill = $('<button type="button" id="jawnos_update_pill" hint="A new build has shipped" style="position:fixed;left:12px;bottom:12px;z-index:2147483000;background:var(--panel);border:2px solid var(--line);border-radius:10px;padding:7px 12px;font-family:inherit;font-size:13px;color:inherit;line-height:1.2;-webkit-appearance:none;appearance:none;cursor:pointer;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;touch-action:manipulation;box-shadow:0 6px 18px rgba(0,0,0,.35);">A fix has shipped — <b>press to update</b></button>');
	pill.on('click', function () { save(); jawnosReloadWhenReady(); });
	$('body').append(pill);
	// the hidden tab does not wait for a press: come back and it is already new
	$(document).on('visibilitychange.jawnos_update_pill', function () {
		if (document.hidden && $('#jawnos_update_pill').length) { save(); jawnosReloadWhenReady(); }
	});
}

// Reload, but only once the tree is actually answering. An update is a push
// followed by a restart: the tab's socket reconnects and hands out the revision
// while the tree is still coming back, and a bare reload in that window lands on
// a closed port - the browser's own error page - leaving the app stranded until
// it is re-entered from the dashboard. Ask the health route (which trusts a
// local caller, so it needs no session) until it answers, then reload; if it
// never does, reload anyway, so a tab is never frozen waiting on a dead tree.
function jawnosReloadWhenReady(attempt) {
	attempt = attempt || 0;
	var go = function () { location.reload(); };
	$.ajax({ url: '/manager/health', type: 'GET', dataType: 'json', cache: false, timeout: 4000 })
		.done(go)
		.fail(function () {
			if (attempt < 40) { setTimeout(function () { jawnosReloadWhenReady(attempt + 1); }, 1000); }
			else { go(); }
		});
}
