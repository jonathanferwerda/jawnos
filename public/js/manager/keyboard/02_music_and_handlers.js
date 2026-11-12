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
	var release = link.hasClass('work_claim_release');
	var url = release ? '/manager/work_claim/release' : '/manager/work_claim';
	$.post(url, { task: link.attr('task') }, function (response) {
		// The claim line sits in the Clock app's time machine tab now, so redraw
		// its two states here instead of fetching a panel that is gone.
		var label = link.closest('.ghosts_claim');
		if (!label.length) { return; }
		var say = function (words) { return (typeof jawnosT == 'function') ? jawnosT(words) : words; };
		var who = (!release && response && response.claim)
			? (response.claim.machine || response.claim.by || '') : '';
		label.empty();
		if (who) {
			label.append(document.createTextNode(say('Ghosts being sorted out:') + ' ' + say('by') + ' '))
				.append($('<b></b>').text(who))
				.append(' ')
				.append($('<a href="#" class="work_claim_release" task="ghosts"></a>').text(say('release')));
		}
		else {
			label.append(document.createTextNode(say('Ghosts being sorted out:') + ' ' + say('nobody') + ' '))
				.append($('<a href="#" class="work_claim_take" task="ghosts"></a>').text(say('take it')));
		}
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
	// A widget face opens the app the widget stands for; a launcher pin hands
	// its press to the start-menu row it was cloned from.
	if ($(this).hasClass('dock_widget')) {
		jawnosDockWidgetOpen($(this).attr('dock_widget'));
		return;
	}
	if ($(this).hasClass('dock_launcher')) {
		if (typeof jawnosTaskbarPress == 'function') { jawnosTaskbarPress($(this).attr('dock_sel')); }
		return;
	}
	// An open window's face answers like the bar's own tile: it restores a
	// minimized window, raises a background one, or minimises the top one.
	if ($(this).hasClass('dock_window')) {
		jawnosDockWindowPress($(this));
		return;
	}
	// Notifications is its own app now: notifications.js opens it from this face,
	// and there is no keyboard panel left to build.
	if (toggle == 'notifications') { return; }
	// The old floating keyboard and calculator are gone: both dock icons now
	// open the JawnOS on-screen keyboard (the calculator on its own page).
	if ((toggle == 'keyboard' || toggle == 'calculator') && typeof softKbDockOpen == 'function') {
		softKbDockOpen(toggle == 'calculator' ? 'calc' : 'letters');
		return;
	}
	// Every other named panel has moved into an app, so a face whose name is
	// not one of the apps above has no panel of its own left to open.
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

	$.ajax({
		url: '/manager/notifications/remove',
		type: 'POST',
		data: { timestamp: timestamp, tag: tag, scope: scope, title: title, uuid: uuid, app: app, server_time: server_time },
		success: function(response) {
			$.each(response, function(i,v) {
				$('.notification[uuid="' + v + '"]').remove();
			});
		}
	});
});

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
