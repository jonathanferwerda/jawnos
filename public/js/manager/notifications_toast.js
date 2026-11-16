// In-program notices: a small card that rises over the desk instead of the
// browser's own Notification, which the desktop showed only when the browser
// felt like it. A notice can be updated in place by its key - the volume card
// does this while a wheel turns - and removes itself after a few seconds, or
// when it is pressed. A notice carrying an app opens that app on a press.
//
// The cards are a stack in the top-right corner, above every window and below
// the soft keyboard. Four at once is the most that may stand; a fifth closes
// the oldest, so a burst of news never covers the desk.
var jawnos_notice_seq = 0;
var jawnos_notice_by_key = {};
var jawnos_notice_order = [];

function jawnosNoticeBox() {
	var box = $('#jawnos_notices');
	if (!box.length) {
		box = $('<div id="jawnos_notices" role="status" aria-live="polite"></div>').appendTo('body');
	}
	return box;
}

function jawnosNoticeClose(key) {
	var card = jawnos_notice_by_key[key];
	if (!card || !card.length) { return; }
	if (card.data('timer')) { clearTimeout(card.data('timer')); }
	delete jawnos_notice_by_key[key];
	jawnos_notice_order = $.grep(jawnos_notice_order, function (k) { return k != key; });
	card.stop(true, true).fadeOut(120, function () { $(this).remove(); });
}

// A zero ttl means "stay until pressed": hovering a card pauses its clock, and
// leaving it starts the clock again from the notice's own ttl.
function jawnosNoticeSchedule(card, key, ttl) {
	if (card.data('timer')) { clearTimeout(card.data('timer')); }
	if (ttl > 0) {
		card.data('timer', setTimeout(function () { jawnosNoticeClose(key); }, ttl));
	}
}

function jawnosNotice(opts) {
	opts = opts || {};
	var box = jawnosNoticeBox();
	var key = opts.key ? String(opts.key) : ('notice_' + (++jawnos_notice_seq));
	var card = jawnos_notice_by_key[key];
	if (!card || !card.length) {
		card = $('<div class="jawnos_notice"></div>').attr('data-notice-key', key);
		var icon = $('<img class="jawnos_notice_icon" alt="">').hide();
		var text = $('<div class="jawnos_notice_text"></div>');
		text.append($('<div class="jawnos_notice_title"></div>'));
		text.append($('<div class="jawnos_notice_body"></div>'));
		var close = $('<button type="button" class="jawnos_notice_close"></button>')
			.attr('aria-label', typeof jawnosT === 'function' ? jawnosT('Close') : 'Close')
			.text('✕');
		card.append(icon).append(text).append(close);
		card.on('mouseenter', function () { jawnosNoticeSchedule(card, key, 0); });
		card.on('mouseleave', function () { jawnosNoticeSchedule(card, key, card.data('ttl') || 6000); });
		card.on('click', '.jawnos_notice_close', function (e) {
			e.stopPropagation();
			jawnosNoticeClose(key);
		});
		card.on('click', function () {
			var app = card.attr('data-notice-app') || '';
			jawnosNoticeClose(key);
			if (app && typeof appWindowOpener === 'function') {
				appWindowOpener(app, Date.now(), { visible: 'yes' });
			}
		});
		box.prepend(card);
		jawnos_notice_by_key[key] = card;
		jawnos_notice_order.unshift(key);
		while (jawnos_notice_order.length > 4) {
			jawnosNoticeClose(jawnos_notice_order[jawnos_notice_order.length - 1]);
		}
	}
	card.attr('data-notice-level', opts.level ? String(opts.level) : 'info');
	card.attr('data-notice-app', opts.app ? String(opts.app) : '');
	card.find('.jawnos_notice_title').text(opts.title || '');
	card.find('.jawnos_notice_body').text(opts.message || '').toggle(!!opts.message);
	var path = opts.icon ? String(opts.icon) : '';
	var img = card.find('.jawnos_notice_icon');
	if (path) { img.attr('src', path).show(); } else { img.hide().removeAttr('src'); }
	var ttl = (opts.ttl === undefined) ? 6000 : parseInt(opts.ttl, 10);
	if (isNaN(ttl)) { ttl = 6000; }
	card.data('ttl', ttl);
	jawnosNoticeSchedule(card, key, ttl);
	return card;
}

// ------------------------------------------------------------------ a press
//
// A notice is a door wherever it is drawn. The Notifications app's rows (and a
// notice the desk injected) open the appointment window of the app they name,
// so a notice is never a dead click. A notice that names no app has no window
// of its own, so it opens Notifications instead. Scan is the one app whose
// notice wants its own screen: the paper pool.
function jawnosNotificationOpener(app, timestamp) {
	app = app ? String(app) : '';
	timestamp = parseInt(timestamp, 10) || Date.now();
	if (app == 'scan' && typeof scanOpener === 'function') { scanOpener(); return; }
	if (app && typeof appointmentGrabber === 'function') {
		appointmentGrabber(app, timestamp, 'notification');
		return;
	}
	if (typeof appWindowOpener === 'function') {
		appWindowOpener(app || 'notifications', timestamp, { visible: 'yes' });
	}
}

$(document).on('click', '.notification', function (e) {
	if ($(e.target).closest('.notification_remove').length) { return; }
	jawnosNotificationOpener($(this).attr('app'), $(this).attr('timestamp'));
});

// The rows are divs with a button's role, so Enter and Space press them too.
$(document).on('keydown', '.notification, .taskbar_notifications_row', function (e) {
	if (e.keyCode != 13 && e.keyCode != 32) { return; }
	if ($(e.target).closest('.notification_remove').length) { return; }
	e.preventDefault();
	$(this).trigger('click');
});
