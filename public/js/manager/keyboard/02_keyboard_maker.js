// A keyboard panel floats over the desk. A fresh one opens centred, with its
// top under the clothesline; panels already open step down and across so the
// newest does not land exactly on the one before it. Nothing may start above
// the viewport (or above the clothesline) or run off an edge.
function keyboardPanelDefaultCSS(panel) {
	panel = $(panel);
	var vw = $(window).width();
	var vh = $(window).height();
	var limit = (typeof panelTopLimit === 'function') ? panelTopLimit() : 0;
	var bar = (typeof jawnosTaskbarHeight === 'function') ? jawnosTaskbarHeight() : 0;
	// measure the panel as the floating box it is about to become
	panel.css({ 'position': 'fixed', 'left': '0px', 'top': '0px', 'right': 'auto', 'bottom': 'auto' });
	var width = panel.outerWidth() || 0;
	var height = panel.outerHeight() || 0;
	var step = $('.keyboard:visible').not(panel).length * 18;
	var left = Math.round((vw - width) / 2 + step);
	var top = Math.round(limit + 18 + step);
	left = Math.max(0, Math.min(left, Math.max(0, vw - width)));
	top = Math.max(limit, Math.min(top, Math.max(limit, vh - height - bar - 8)));
	return {
		'position': 'fixed',
		'left': left + 'px',
		'top': top + 'px',
		'right': 'auto',
		'bottom': 'auto',
		'max-height': Math.max(120, vh - limit - bar - 16) + 'px',
		'max-width': Math.max(220, vw - 16) + 'px',
		'overflow': 'auto'
	};
}

// A saved spot is re-checked against this screen before it is painted: a panel
// left high on a larger screen must not start above the viewport, and its size
// is capped to the room left under the clothesline.
function keyboardPanelClamp(panel, css) {
	panel = $(panel);
	if (!css) { return css; }
	// An older save could leave a panel in the page's flow (a drag used to make
	// it position:relative). A keyboard panel always floats now, so a saved spot
	// is read as a fixed one rather than bringing the missing frame back.
	if (css['position'] != 'fixed') { css['position'] = 'fixed'; }
	var vw = $(window).width();
	var vh = $(window).height();
	var limit = (typeof panelTopLimit === 'function') ? panelTopLimit() : 0;
	var bar = (typeof jawnosTaskbarHeight === 'function') ? jawnosTaskbarHeight() : 0;
	var top = (css['top'] != null && css['top'] !== 'auto') ? parseFloat(css['top']) : NaN;
	if (isFinite(top) && top < limit) { css['top'] = limit + 'px'; }
	var width = panel.length ? (panel.outerWidth() || 0) : 0;
	var left = (css['left'] != null && css['left'] !== 'auto') ? parseFloat(css['left']) : NaN;
	var right = (css['right'] != null && css['right'] !== 'auto') ? parseFloat(css['right']) : NaN;
	if (isFinite(left) && !isFinite(right)) {
		left = Math.max(0, Math.min(left, Math.max(0, vw - width)));
		css['left'] = left + 'px';
	}
	css['max-height'] = Math.max(120, vh - limit - bar - 16) + 'px';
	css['max-width'] = Math.max(220, vw - 16) + 'px';
	css['overflow'] = 'auto';
	return css;
}

// A panel still wearing its default spot follows a reshaped screen; one the
// person has moved keeps the spot it was given.
$(window).on('resize', function() {
	$('.keyboard[default_placed="yes"]:visible').each(function() {
		$(this).css(keyboardPanelDefaultCSS(this));
	});
});

async function keyboardMaker(data) {
	var toggle = data['toggle'];
	var state = data['state'];
	var remote_uuid = data['remote_uuid'];
	var timestamp = Date.now();
	var pseudonym = $('#' + toggle + '_toggle');
	if (!toggle) {
		return;
	}
	var t = $('#' + toggle);
	var h = $(window).height();
	var w = $(window).width();
	// A panel can also be opened without a dock face (a machine's card on the
	// System page): there is no icon to measure, so it opens at its default.
	var o = pseudonym.length ? pseudonym.offset() : null;
	if (!o) { o = { top: h, left: 0 }; }
	var bottom = h - o.top;

	var av = [];
	try {
		if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
			av = await navigator.mediaDevices.enumerateDevices();
		}
	}
	catch (e) { av = []; }
	var avData = JSON.stringify(av);

	if (toggle == 'walkboy') {
		var seen = 0;
		$.each(av, function(i,v) {
			if (v.deviceId != '') {
				seen++;
			}
		});

		if (seen == 0) {
			permissionAsker('media');
			return;
		}
	}
	// Where the panel was left. Its own drag bar keeps the whole spot (the style
	// dump the bar's stop writes); a panel never moved falls back to the place its
	// dock icon was dropped in, or to its default against the dock. The panel's own
	// spot wins, because that is the one a person moves.
	var css = null;
	var kept_style = jawnosWindowStyleGet(toggle);
	if (kept_style) {
		try { css = JSON.parse(kept_style); } catch (e) { css = null; }
	}
	if (css == null) {
		var pos = jawnosWindowPlaceGet(toggle + '_toggle');
		if (pos) {
			var ps = JSON.parse(pos);
			var top = ps.top + 60;
			var left = ps.left;
			css = { 'position': 'fixed', 'top': top, 'left': left };
			if (bottom < h / 4) {
				delete css['top'];
				css['bottom'] = 20;
				css['height'] = $('#' + toggle).height();
				css['width'] = $('#pseudonym_home').width();
				css['left'] = $('#pseudonym_home').offset().left;
			}
			else {
				css['height'] = $('#' + toggle).height();
				var jcss = JSON.stringify(css);
				jawnosWindowStyleSet(toggle, jcss);
				jawnosWindowPlaceSet(toggle, jcss);
			}
		}
	}
	if (css) {
		// A panel restored from its saved spot can be above the clothesline or off
		// the screen; the drag clamps a moved one, so clamp the first paint too.
		css = keyboardPanelClamp($('#' + toggle), css);
		$('#' + toggle).css(css);
	}
	if (!t.is(':visible') && !t.hasClass('keyboard') || state == 'on') {
		var data = {
			timestamp: timestamp,
			toggle: toggle,
			avData: avData,
			browser_tab_id: bti,
			remote_uuid: remote_uuid
		};

		$.ajax({ 
			url: '/manager/keyboard',
			type: 'POST',
			data: data,
			success: function(response) {
				$('#' + toggle).remove();
				if (typeof response.keyboard === 'string') { $('#keyboard_container').append(response.keyboard); }
				if (toggle == 'remote_control') {
					// keep the picker on the machine that was just chosen, and take
					// the Manager button with it (the setting POST can land after this
					// render, so the server's selected option may still be the old one).
					// A machine can be named by its signatorial (a System card does),
					// which is not an option value: then the server's own selection is
					// already right, so leave it alone.
					if (typeof remote_uuid === 'string' && $('#remote_control_machine_select option').filter(function() { return this.value === remote_uuid; }).length) {
						$('#remote_control_machine_select').val(remote_uuid);
					}
					keyboardManagerButton();
					jawnosVpnRefresh();
					if (typeof jawnosPublicIpRefresh == 'function') { jawnosPublicIpRefresh(); }
					if (typeof jawnosRemoteInputInit == 'function') { jawnosRemoteInputInit(); }
				}


				var t = $('#' + toggle);
				t.show();
				$('.typewriter').show();
				$('#time_machine').val(localStorage.getItem('time_machine')	);
				initializer();
				// a re-rendered panel starts on the markup's idle text; ask once
				musicReceiverRefresh();
				if (css) {
					t.removeAttr('default_placed');
					// a saved width is the one the person resized to; only a panel that
					// has never been sized takes its own default here
					if (css['width'] == null || css['width'] === '') { css['width'] = t.width(); }
					t.css(keyboardPanelClamp(t, css));
				}
				else {
					// A panel that has never been moved still needs a frame: it opens
					// in the desk's default spot rather than in the page's flow, and
					// keeps that spot when the screen changes shape until it is moved.
					t.attr('default_placed', 'yes');
					t.css(keyboardPanelDefaultCSS(t));
				}
				t.attr('claimed', 'yes');
				keyboardDragBarMaker(t);
			}
		});
	}
	else if (!t.is(':visible')) {
		$('#' + toggle).show();
		if (css) {
			$('#' + toggle).removeAttr('default_placed').css(keyboardPanelClamp($('#' + toggle), css));
		}
		else {
			$('#' + toggle).attr('default_placed', 'yes').css(keyboardPanelDefaultCSS($('#' + toggle)));
		}
		$('#' + toggle).attr('claimed', 'yes');
		keyboardDragBarMaker($('#' + toggle));
	}
	else if (state != 'on') {
		$('#' + toggle).parent().remove();
		if (toggle == 'remote_control') {
			$('#search').val('');
			if (typeof jawnosRemoteInputStop == 'function') { jawnosRemoteInputStop(); }
		}
	}
	var togglerInterval = setInterval(function() {
		var l = $('#' + toggle).offset();
		if (l != undefined) {
			setTimeout(function() {
				clearInterval(togglerInterval);
				// nothing was kept to clamp: the panel is wearing its own CSS default
				if (!css) { return; }
				var wow = l.left;
				var toggle_width = $('#' + toggle).width();
				var wow_right = wow + toggle_width;

				if (wow_right >= w) {

					css['left'] = w - toggle_width;
					css['width'] = toggle_width;
				//	css['max-width'] = "100%";
					delete css['right'];
				}
				else if (wow <= 0) {

					css['left'] = 0;
					css['width'] = toggle_width;
				//	css['max-width'] = "100%";
					delete css['right'];
				}
				$('.media_picker').each(function(i,v) {
					var kind = $(v).attr('kind');
					var deviceId = $(v).attr('device_id');
					var status = 'off';


						var input = jawnosDevicePickGet(kind, deviceId);

						if (input == 'on') { status = 'on' }
						$(v).attr('selected','selected');
				});
				$('#' + toggle).css(css);
			},1);
		}
	},100);
}

// Music sent here by another machine is played by the receiver with `play`:
// there is no window and no player to press, only the two markers the receiver
// leaves. The keyboard's strip reports what is arriving, stops it, and can
// refuse further transmissions to this machine.
function musicReceiverText(words) {
	return (typeof jawnosT === 'function') ? jawnosT(words) : words;
}
function musicReceiverDraw(state) {
	var boxes = $('.music_receiver_control');
	if (!boxes.length) { return; }
	var file = (state && state.file) ? String(state.file).split('/').pop() : '';
	var playing = !!(state && state.playing);
	var blocked = !!(state && state.blocked);
	boxes.each(function () {
		var box = $(this);
		var title = box.find('.music_receiver_title');
		if (playing) {
			title.text(musicReceiverText('Receiving') + (file ? ': ' + file : ''));
		}
		else if (blocked) {
			title.text(musicReceiverText('Music from other devices is off'));
		}
		else {
			title.text(musicReceiverText('No music is playing here'));
		}
		box.attr('status', playing ? 'playing' : (blocked ? 'blocked' : 'idle'));
		box.find('.music_receiver_stop').css({ 'display': playing ? '' : 'none' });
		box.find('.music_receiver_block').prop('checked', blocked);
	});
}
function musicReceiverRefresh() {
	if (!$('.music_receiver_control:visible').length) { return; }
	$.ajax({
		url: '/manager/music/receiver',
		type: 'GET',
		dataType: 'json',
		success: musicReceiverDraw
	});
}
$(document).on('click', '.music_receiver_stop', function() {
	var button = $(this);
	button.prop('disabled', true);
	$.post('/manager/music/receiver/stop', {}, function (state) {
		button.prop('disabled', false);
		musicReceiverDraw(state);
	});
});
$(document).on('change', '.music_receiver_block', function() {
	$.post('/manager/music/receiver/block', { blocked: $(this).is(':checked') ? 'on' : 'off' }, musicReceiverDraw);
});
setInterval(musicReceiverRefresh, 5000);

// The Go button follows the machine picker at once, rather than waiting for
// the setting POST and the next render.
function keyboardManagerButton(select) {
	var s = select ? $(select) : $('#remote_control_machine_select');
	var picked = s.find('option:selected');
	var buttons = $('#remote_control_go');
	if (!buttons.length) { return; }
	if (!picked.length || !picked.val()) {
		buttons.hide().removeAttr('uuid').removeAttr('manager');
		return;
	}
	buttons.attr('uuid', picked.val()).attr('manager', picked.attr('manager') || '').show();
}

function keyboardConfigToggle(toggle) {
	var keyboard = $('#' + toggle);
	var config = $('.keyboard_config[toggle="' + toggle + '"]')
	var remote_uuid = config.attr('remote_uuid');

	var content = keyboard.find('.keyboard_content');
	if (config.is(':visible')) {
		config.hide();
		content.show();
	}
	else {
		content.hide();

		$.ajax({
			url: '/manager/keyboard/config',
			type: 'GET',
			data: { toggle: toggle, remote_uuid: remote_uuid },
			success: function(response) {

				config.html(response.html);
				config.show();
			}
		});
	}
}

// The delorean's config: the two sensitivities ride on the globals the timeline
// and the clothesline actually read, so a change is felt at once, and each is
// kept on the server per device (settingSetter sends no device, which is how
// the server reads it as this one).
var keyboard_sensitivity_setter;
$(document).on('input', '.keyboard_sensitivity', function() {
	var slider = $(this);
	var setting = slider.attr('setting');
	var value = numeral(slider.val()).value();
	$('.keyboard_sensitivity_viewer[setting="' + setting + '"]').text(value);
	if (typeof keyboard_sensitivity == 'undefined') { keyboard_sensitivity = {}; }
	if (setting == 'clothesline_sensitivity') {
		clotheslineSensitivity = value;
		keyboard_sensitivity['clothesline'] = value;
	}
	else {
		trackpadSensitivity = value;
		keyboard_sensitivity['trackpad'] = value;
	}
	// one save once the slider settles, not one per step
	clearTimeout(keyboard_sensitivity_setter);
	keyboard_sensitivity_setter = setTimeout(function() {
		settingSetter({ 'app': 'keyboard', 'setting': setting, 'value': value });
	}, 500);
});

$(document).on('change', '#timestamp_in_view', function() {
	var value = $(this).is(':checked') ? 'checked' : 'unchecked';
	settingSetter({ 'app': 'keyboard', 'setting': 'timestamp_in_view', 'value': value });
});

// Ghost appointments: the events the records say will probably happen. The setting
// rides the server (it builds the ghosts into the viewer's payload), so a change
// only has to re-fetch the view.
$(document).on('change', '#ghost_appointments', function() {
	var value = $(this).is(':checked') ? 'checked' : 'unchecked';
	settingSetter({ 'app': 'keyboard', 'setting': 'ghost_appointments', 'value': value });
	if (typeof calculator == 'function') { calculator(); }
});

$(document).on('change', '#clothesline_on', function() {
	var value = $(this).is(':checked') ? 'on' : 'off';
	settingSetter({ 'app': 'misc', 'setting': 'clothesline_on', 'value': value });
	if (typeof clotheslineToggleApply == 'function') { clotheslineToggleApply(value); }
});
$(document).on('change', '#appt_walkman_global', function() {
	var value = $(this).is(':checked') ? 'checked' : 'unchecked';
	settingSetter({ 'app': 'keyboard', 'setting': 'appt_walkman_global', 'value': value });
	// the walkman handler reads this seed, so the next press obeys at once
	if (typeof jawnos_bar_settings != 'undefined') { jawnos_bar_settings['appt_walkman_global'] = value; }
});

// A work claim says which machine is on a job, so two agents do not take the same
// one. It rides the 'claims' app, which the mesh carries to every machine.
$(document).on('click', '.work_claim_take, .work_claim_release', function(e) {
	e.preventDefault();
	var link = $(this);
	var url = link.hasClass('work_claim_release') ? '/manager/work_claim/release' : '/manager/work_claim';
	$.post(url, { task: link.attr('task') }, function () {
		keyboardConfigToggle('delorean');
		keyboardConfigToggle('delorean');
	});
});

$(document).on('click', '.keyboard_base', function() {
	var b = $(this);
	var toggle = b.attr('toggle');
	var p = $('.pseudonym.keyboard[toggle="' + toggle + '"]');
	var q = jawnosDockIconGet(toggle);

	if (q == 'on') {
		p.hide();
		b.css({'background-color': 'yellow' });
		jawnosDockIconSet(toggle, 'off');
	}
	else {
		p.show();
		jawnosDockIconSet(toggle, 'on');
		b.css({'background-color': 'green' });
	}
	//say_it(b.attr('speech'));

});


$(document).on('click','.pseudonym', function() {
	var toggle = $(this).attr('toggle');
	// A browser-added app face opens its app window (or raises/minimises it);
	// it has no keyboard panel of its own.
	if ($(this).hasClass('dock_app')) {
		jawnosDockAppOpen($(this).attr('dock_app'));
		return;
	}
	// The old floating keyboard and calculator are gone: both dock icons now
	// open the JawnOS on-screen keyboard (the calculator on its own page).
	if ((toggle == 'keyboard' || toggle == 'calculator') && typeof softKbDockOpen == 'function') {
		softKbDockOpen(toggle == 'calculator' ? 'calc' : 'letters');
		return;
	}
	var panel = $('#' + toggle);
	// A click is the open gesture. The dock's own state can lag the panel (the
	// first click used to render and the click then remove it before it showed),
	// so decide by what is actually on screen: open when it is hidden, close
	// when it is visible.
	if (panel.length && panel.is(':visible')) {
		panel.remove();
	}
	else {
		keyboardMaker({ toggle: toggle, state: 'on' });
	}
});



$(document).on('click', '.notification_remove', function() {
	var b = $(this);
	var timestamp = b.attr('timestamp');
	var title = b.attr('title');
	var tag = b.attr('tag');
	var uuid = b.attr('uuid');
	var scope = b.attr('scope');
	var app = b.attr('app');
	var server_time = b.attr('server_time');
	var filter = $('#notification_app_select').val();
	var search = $('#notification_search').val();

	$.ajax({
		url: '/manager/notifications/remove',
		type: 'POST',
		data: { timestamp: timestamp, tag: tag, filter: filter, search: search, scope: scope, title: title, uuid: uuid, app: app, server_time: server_time },
		success: function(response) {
			$.each(response, function(i,v) {
				$('.notification[uuid="' + v + '"]').remove();
			});
			notificationScrollLoader();
		}
	});
});

$(document).on('change', '#notification_app_select', function() {
	var app = $(this).val();

	$.ajax({ 
		url: '/manager/notifications/filter',
		type: 'GET',
		data: { app: app },
		success: function(response) {
			$('#notifications_content').html(response.content);
		}
	});
});

$(document).on('keyup', '#notification_search', function() {
	var search = $(this).val();

	$.ajax({
		url: '/manager/notifications/search',
		type: 'GET',
		data: { search: search },
		success: function(response) {
			$('#notifications_content').html(response.content);
		}
	});
});

var notificationReload = { reload: 0, position: 1 };

$(document).on('mousewheel touchmove', '#notifications_content', function() {
	notificationScrollLoader();

});

function notificationScrollLoader() {
	var nc = $('#notifications_content');
	if (!nc.length) { return; }
	var scroll = nc.offset().top;
	var height = nc.height();
	var cheight = $('#notifications').height();

	if ((height - (cheight + Math.abs(scroll))) < 530) {
		if (notificationReload['reload'] == 0) {
			notificationReload['reload'] = 1;
			$.ajax({
				url: '/manager/notifications/scroll',
				type: 'GET',
				data: { position: notificationReload['position'] },
				success: function(response) {
					$('#notifications_content').append(response.content);
					notificationReload['reload'] = 0;
					notificationReload['position']++;
				}
			});
		}
		
	}
}

function initializer() {
	var scope = localStorage.getItem('scope');
	var timeshift = localStorage.getItem('timeshift');
	var timeshift_scope = localStorage.getItem('timeshift_scope');
	var sorts = localStorage.getItem('sorts');
	var filter = localStorage.getItem('filter');
	var layout = localStorage.getItem('layout');
	var update_frequency = localStorage.getItem('update_frequency');
	var keyboard = localStorage.getItem('keyboard');
	var search = localStorage.getItem('search');
	var time_machine = localStorage.getItem('time_machine');
	var project = localStorage.getItem('project');
	var account = localStorage.getItem('account');
	var room_check = localStorage.getItem('room_check');
	var windshield_wiper = localStorage.getItem('windshield_wiper');
	var background_images = localStorage.getItem('background_images');
	var background_images_opacity = localStorage.getItem('background_images_opacity');
	if (!scope) {
		keyboard = 'none';
		localStorage.setItem('keyboard', keyboard);
		update_frequency = '3000';
		localStorage.setItem('update_frequency', update_frequency);
		scope = 'fifteenminute';
		localStorage.setItem('scope', scope);
		timeshift_scope = 's';
		localStorage.setItem('timeshift_scope', timeshift_scope);
		layout = 'desk';
		localStorage.setItem('layout', layout);
		sorts = 'timestamp';
		localStorage.setItem('sorts', sorts);
		timeshift = 0;
		localStorage.setItem('timeshift', timeshift);
		filter = 'all';
		localStorage.setItem('filter', filter);
		time_machine = '';
		localStorage.setItem('time_machine',time_machine);
		project = 'all';
		localStorage.setItem('project',project);
		account = 'all';
		localStorage.setItem('account',account);
	}
	if ($('#scope').is(':visible')) {
		$('#scope').val(scope);
		$('#layout').val(layout);
		$('#sorts').val(sorts);
		$('#timeshift').val(timeshift);
		$('#timeshift_scope').val(timeshift_scope);
		$('#update_frequency').val(update_frequency);
		$('#time_machine').val(time_machine);
		$('#filter').val(filter);
		$('#projects').val(project);
		$('#accounts').val(account);
		$('#background_images_opacity').val(background_images_opacity);
		if (background_images == 'on') {
			$('#background_images').prop('checked', true);
		}
	}
	if ($('#layout').is(':visible')) {
		$('#layout').val(layout);
	}
	$.each(['room_check','windshield_wiper'], function(i,v) {
		if (localStorage.getItem(v) == 'true') {
			$('#' + v).prop('checked',true);
		}

	});

	clearInterval(calculateInterval);
	var frequency_value = numeral(update_frequency).value();
	if (frequency_value < 1000) { frequency_value = 1000; }
	if (update_frequency != "no") {
		calculateInterval = setInterval(function() {
			calculator();
		}, frequency_value);
	}
	timestampDater();
	appointment_chron();
	var shadow = localStorage.getItem('mouse_shadow');
	if (shadow) {
		$('#mouse_shadow').css(JSON.parse(localStorage.getItem('mouse_shadow')));
	}
	debrief_setter();
}

