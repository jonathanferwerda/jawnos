// ------------------------------------------------------------- alarm ring
// The claim is per window, not per browser. localStorage is shared by every
// Manager window on the machine, so a stored claim let only the first window
// draw the ring - usually not the one in front of the person. Each window now
// keeps its own short guard against the two notices (this machine's ring and a
// peer's) describing the same alarm.
var jawnosClockRingSeen = {};
var jawnosClockRingGuardTimer = null;
function jawnosClockRingClaim(uuid) {
	var now = Date.now();
	if (jawnosClockRingSeen[uuid] && now - jawnosClockRingSeen[uuid] < 15000) { return false; }
	jawnosClockRingSeen[uuid] = now;
	return true;
}

function jawnosClockRingCard() {
	var card = $('#clock_ring_overlay');
	if (card.length) { return card; }
	card = $('<div id="clock_ring_overlay" class="clock_ring_overlay" style="display:none;">'
		+ '<div class="clock_ring_card">'
		+ '<div class="clock_ring_title">' + jawnosClockEsc(jawnosT('alarm_ringing')) + '</div>'
		+ '<div class="clock_ring_label"></div>'
		+ '<div class="clock_ring_time"></div>'
		+ '<div class="clock_ring_math" style="display:none;">'
		+ '<div class="clock_ring_math_problem"></div>'
		+ '<input type="text" inputmode="numeric" autocomplete="off" autocapitalize="off" spellcheck="false" class="clock_ring_math_input" aria-label="' + jawnosClockEsc(jawnosT('math')) + '">'
		+ '<div class="clock_ring_math_feedback"></div>'
		+ '</div>'
		+ '<div class="clock_ring_nfc_note" style="display:none;"></div>'
		+ '<div class="clock_ring_buttons">'
		+ '<button type="button" class="clock_ring_snooze" title="' + jawnosClockEsc(jawnosClockSnoozeText(5)) + '">' + jawnosClockEsc(jawnosClockSnoozeText(5)) + '</button>'
		+ '<button type="button" class="clock_ring_dismiss">' + jawnosClockEsc(jawnosT('dismiss')) + '</button>'
		+ '</div>'
		+ '</div></div>');
	$('body').append(card);
	return card;
}

// A basic problem with a non-negative answer: a x b - c.
function jawnosClockMathMake() {
	var a = 2 + Math.floor(Math.random() * 11);
	var b = 2 + Math.floor(Math.random() * 11);
	var c = Math.floor(Math.random() * (Math.min(12, a * b) + 1));
	return { a: a, b: b, c: c, answer: a * b - c };
}

function jawnosClockMathStart(card) {
	var m = jawnosClockMathMake();
	jawnosClockRingMath = { a: m.a, b: m.b, c: m.c, answer: m.answer, solved: false };
	card.find('.clock_ring_math_problem').text(m.a + ' × ' + m.b + ' − ' + m.c + ' = ?');
	card.find('.clock_ring_math_input').val('').removeClass('ok bad');
	// The phone's alarm screen is where the math is enforced. This window is
	// the acknowledged way past it (unlock the phone, answer from the Clock
	// window), so the buttons here always work.
	card.find('.clock_ring_math_feedback').removeClass('ok bad').text(jawnosT('The buttons below still snooze or dismiss from this window.'));
	card.find('.clock_ring_math').show();
}

// Type the answer for fun; it never locks the buttons, which are the bypass.
function jawnosClockMathCheck(card) {
	if (!jawnosClockRingMath) { return; }
	var m = jawnosClockRingMath;
	var input = card.find('.clock_ring_math_input');
	var feedback = card.find('.clock_ring_math_feedback');
	var value = parseInt(String(input.val() || '').replace(/[^0-9]/g, ''), 10);
	if (isNaN(value)) {
		m.solved = false;
		input.removeClass('ok bad');
		feedback.removeClass('ok bad').text(jawnosT('The buttons below still snooze or dismiss from this window.'));
		return;
	}
	if (value === m.answer) {
		m.solved = true;
		input.addClass('ok').removeClass('bad');
		feedback.addClass('ok').removeClass('bad').text(jawnosT('Correct'));
	}
	else {
		m.solved = false;
		input.addClass('bad').removeClass('ok');
		feedback.addClass('bad').removeClass('ok').text(jawnosT('Try again'));
	}
}

function jawnosClockMathReset(card) {
	jawnosClockRingMath = null;
	card.find('.clock_ring_math').hide();
	card.find('.clock_ring_math_problem').text('');
	card.find('.clock_ring_math_input').val('').removeClass('ok bad');
	card.find('.clock_ring_math_feedback').text('').removeClass('ok bad');
	card.find('.clock_ring_buttons button').prop('disabled', false);
}

function jawnosClockShowRing(payload) {
	jawnosClockRingingCurrent = payload;
	// The server's ring guard is five minutes. A card shown from a peer's
	// notice can outlive the shared row's ringing flag for a moment, so the
	// card takes itself down when that guard has run out even if no state
	// poll answers.
	payload.ring_at = payload.fired_at || payload.at || Date.now();
	jawnosClockRingGuardArm();
	var card = jawnosClockRingCard();
	card.find('.clock_ring_label').text(payload.label || jawnosT('alarm'));
	card.find('.clock_ring_time').text(jawnosClockTime(payload.hour, payload.minute) + (payload.app ? ' · ' + String(payload.app).replace(/_/g, ' ') : ''));
	card.find('.clock_ring_snooze').text(jawnosClockSnoozeText(payload.snooze)).attr('title', jawnosClockSnoozeText(payload.snooze));
	jawnosClockMathReset(card);
	if (payload.nfc) {
		card.find('.clock_ring_nfc_note').text(jawnosT('The phone asks for the NFC tag; this window can still snooze or dismiss.')).show();
	}
	else {
		card.find('.clock_ring_nfc_note').text('').hide();
	}
	if (payload.play == 'math') { jawnosClockMathStart(card); }
	card.show();
	$('.clock_alarm[data-uuid="' + payload.uuid + '"]').addClass('ringing');
	// The sound is the server's: it plays through the operating system and
	// repeats there until Dismiss or Snooze clears the alarm.
	jawnosClockShowTitle(jawnosT('alarm_ringing') + ': ' + (payload.label || ''));
	setTimeout(function () { jawnosClockRefresh(true); }, 1200);
}

function jawnosClockAlarmRing(payload) {
	if (!payload || !payload.uuid) { return; }
	if (!jawnosClockRingClaim(payload.uuid)) { return; }
	var found = $.grep(jawnosClockRinging, function (a) { return a.uuid == payload.uuid; });
	if (found.length) { return; }
	jawnosClockRinging.push(payload);
	if (!jawnosClockRingingCurrent) { jawnosClockShowRing(jawnosClockRinging.shift()); }
}

function jawnosClockRingGuardArm() {
	if (jawnosClockRingGuardTimer) { clearTimeout(jawnosClockRingGuardTimer); }
	var current = jawnosClockRingingCurrent;
	var at = current && current.ring_at ? current.ring_at : 0;
	var left = at ? 300000 - (Date.now() - at) : 300000;
	if (left < 1000) { left = 1000; }
	jawnosClockRingGuardTimer = setTimeout(function () {
		jawnosClockRingGuardTimer = null;
		if (jawnosClockRingingCurrent) { jawnosClockAlarmStop(); }
	}, left);
}

function jawnosClockAlarmStop() {
	if (jawnosClockRingGuardTimer) {
		clearTimeout(jawnosClockRingGuardTimer);
		jawnosClockRingGuardTimer = null;
	}
	jawnosClockRingingCurrent = null;
	var card = $('#clock_ring_overlay');
	if (card.length) {
		jawnosClockMathReset(card);
		card.find('.clock_ring_nfc_note').text('').hide();
	}
	$('#clock_ring_overlay').hide();
	$('.clock_alarm.ringing').removeClass('ringing');
	jawnosClockShowTitle('');
	if (jawnosClockRinging.length) { jawnosClockShowRing(jawnosClockRinging.shift()); }
}

$(document).on('input', '.clock_ring_math_input', function () {
	var card = $(this).closest('#clock_ring_overlay');
	var m = jawnosClockRingMath;
	if (!m) { return; }
	$(this).removeClass('bad');
	card.find('.clock_ring_math_feedback').removeClass('bad ok').text('');
	// Editing the answer never locks the window's buttons.
	if (m.solved) {
		var value = parseInt(String($(this).val() || '').replace(/[^0-9]/g, ''), 10);
		if (isNaN(value) || value !== m.answer) {
			m.solved = false;
			$(this).removeClass('ok');
		}
	}
});

$(document).on('change', '.clock_ring_math_input', function () {
	jawnosClockMathCheck($(this).closest('#clock_ring_overlay'));
});

$(document).on('keydown', '.clock_ring_math_input', function (e) {
	if (e.key != 'Enter') { return; }
	e.preventDefault();
	jawnosClockMathCheck($(this).closest('#clock_ring_overlay'));
});

$(document).on('click', '.clock_ring_dismiss', function () {
	if (!jawnosClockRingingCurrent) { return; }
	var payload = jawnosClockRingingCurrent;
	jawnosClockPost('/manager/clock/alarm', { action: 'dismiss', uuid: payload.uuid }, function () {
		jawnosClockAlarmStop();
	});
	jawnosClockAlarmStop();
});

$(document).on('click', '.clock_ring_snooze', function () {
	if (!jawnosClockRingingCurrent) { return; }
	var payload = jawnosClockRingingCurrent;
	jawnosClockPost('/manager/clock/alarm', { action: 'snooze', uuid: payload.uuid, minutes: jawnosClockSnoozeValue(payload.snooze) }, function () {
		jawnosClockAlarmStop();
	});
	jawnosClockAlarmStop();
});

function jawnosClockTimerDone(payload) {
	if (!payload) { return; }
	jawnosClockToastEnsure();
	var toast = $('#clock_toast');
	toast.find('.clock_toast_text').text(jawnosT('timer_finished') + ': ' + (payload.label || ''));
	toast.stop(true, true).fadeIn(120);
	clearTimeout(toast.data('hide'));
	toast.data('hide', setTimeout(function () { toast.fadeOut(200); }, 12000));
	// The chime is the server's notification, played through the operating
	// system; the browser only shows the finished notice.
	jawnosClockShowTitle(jawnosT('timer_finished'));
	jawnosClockRefresh(true);
}

function jawnosClockToastEnsure() {
	var toast = $('#clock_toast');
	if (!toast.length) {
		toast = $('<div id="clock_toast" class="clock_toast" style="display:none;"><span class="clock_toast_text"></span><button type="button" class="clock_toast_close" aria-label="' + jawnosClockEsc(jawnosT('dismiss')) + '">✕</button></div>');
		$('body').append(toast);
	}
	return toast;
}

$(document).on('click', '.clock_toast_close', function () {
	$(this).closest('#clock_toast').fadeOut(150);
	jawnosClockShowTitle('');
});

function jawnosClockToast(text) {
	if (!text) { return; }
	var toast = jawnosClockToastEnsure();
	toast.find('.clock_toast_text').text(text);
	toast.stop(true, true).fadeIn(120);
	clearTimeout(toast.data('hide'));
	toast.data('hide', setTimeout(function () { toast.fadeOut(200); }, 6000));
}

var jawnosClockBaseTitle = null;
function jawnosClockShowTitle(text) {
	try {
		if (jawnosClockBaseTitle === null) { jawnosClockBaseTitle = document.title; }
		document.title = text ? text + ' - JawnOS' : jawnosClockBaseTitle;
	} catch (e) {}
}

// ------------------------------------------------------------- taskbar menu
function jawnosClockNavOpen() {
	var nav = $('#clock_nav');
	if (!nav.length) { return; }
	nav.addClass('open').show();
	jawnosClockNavPlace();
}

function jawnosClockNavClose() {
	$('#clock_nav').removeClass('open').hide();
}

function jawnosClockNavToggle() {
	if ($('#clock_nav').hasClass('open')) { jawnosClockNavClose(); }
	else { jawnosClockNavOpen(); }
}

function jawnosClockNavPlace() {
	var nav = $('#clock_nav');
	var clock = $('#taskbar_clock');
	if (!nav.length || !clock.length || !nav.is(':visible') || !clock.is(':visible')) { return; }
	var rect = clock[0].getBoundingClientRect();
	var width = $(window).width();
	var height = $(window).height();
	var gap = 4;
	var nav_width = Math.min(nav.outerWidth() || 200, width);
	var left = rect.right - nav_width;
	left = Math.max(4, Math.min(left, width - nav_width - 4));
	// The menu hangs away from the bar: below a top bar, above a bottom bar,
	// and below a bar on either side (where it is not off the top or bottom of
	// the screen).
	var edge = $('#taskbar').attr('position') || (typeof jawnosBars != 'undefined' ? jawnosBars.taskbar : 'bottom');
	var below = (edge != 'bottom');
	var place = { left: Math.round(left) + 'px', right: 'auto' };
	if (below) {
		place.top = Math.round(rect.bottom + gap) + 'px';
		place.bottom = 'auto';
	}
	else {
		place.bottom = Math.round(height - rect.top + gap) + 'px';
		place.top = 'auto';
	}
	if (place.top != 'auto') {
		var max_height = height - (rect.bottom + gap) - 8;
		if (max_height < 100) { max_height = 100; }
		nav.css('max-height', Math.round(max_height) + 'px');
	}
	else {
		var max_height2 = rect.top - gap - 8;
		if (max_height2 < 100) { max_height2 = 100; }
		nav.css('max-height', Math.round(max_height2) + 'px');
	}
	nav.css(place);
}

$(document).on('click', '#taskbar_clock', function (e) {
	if ($(e.target).is('.taskbar_clock_input')) { return; }
	if (typeof jawnosClockEditing == 'function' && jawnosClockEditing()) { return; }
	if (typeof jawnosTaskbarEditing == 'function' && jawnosTaskbarEditing()) { return; }
	jawnosClockNavToggle();
});

$(document).on('click', '#clock_nav [data-clock-action="time_machine"]', function () {
	jawnosClockNavClose();
	jawnosClockOpenTimeMachine();
});

// The taskbar clock's Time Machine row opens the Clock app on its time-machine
// tab; a fresh window renders after the opener, so retry once for the tab.
function jawnosClockOpenTimeMachine() {
	if (typeof appWindowOpener == 'function') { appWindowOpener('clock', Date.now(), { visible: 'yes' }); }
	var show = function () {
		var tab = $('.wind[app="clock"] .clock_tab[data-clock-tab="machine"]');
		if (!tab.length) { return false; }
		tab.trigger('click');
		return true;
	};
	if (!show()) { setTimeout(show, 400); }
}

$(document).on('click', function (e) {
	if (!$(e.target).closest('#clock_nav, #taskbar_clock').length) { jawnosClockNavClose(); }
});

$(document).on('keydown', function (e) {
	if (e.keyCode == 27) { jawnosClockNavClose(); }
});

$(window).on('resize', function () {
	if ($('#clock_nav').hasClass('open')) { jawnosClockNavPlace(); }
});
