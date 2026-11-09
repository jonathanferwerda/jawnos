// The taskbar's volume widget. It is core, not part of the Sound app's lazy
// chunk: the volume must be readable before the Sound window is ever opened.
// The reading is the same /manager/sound_status the app uses, polled twice a
// minute while the taskbar is on screen. Clicking the widget opens the app.
var jawnosSoundTaskbarData = null;

function jawnosSoundTaskbarRender(status) {
	var widget = $('#taskbar_sound');
	if (!widget.length) { return; }
	jawnosSoundTaskbarData = status;
	var output = status && status.output;
	if (!status || !status.ok || !output) {
		widget.attr('hidden', 'hidden').hide();
		return;
	}
	var pct = Math.max(0, Math.min(100, Math.round(parseFloat(output.volume) || 0)));
	var muted = output.muted ? 1 : 0;
	widget.attr('state', muted ? 'muted' : 'on').attr('level', pct);
	widget.find('.taskbar_sound_waves i').each(function(index) {
		$(this).toggleClass('on', !muted && pct > (index + 1) * 18);
	});
	widget.find('.taskbar_sound_text').text(muted ? jawnosT('sound_muted') : pct + '%');
	var title = jawnosT('sound') + ' — ' + (muted ? jawnosT('sound_muted') : pct + '%');
	if (output.name) { title += ' — ' + output.name; }
	widget.attr('title', title).removeAttr('hidden').show();
}

function jawnosSoundTaskbarLoad() {
	if (!$('#taskbar_sound').length) { return; }
	if (typeof document !== 'undefined' && document.hidden) { return; }
	$.ajax({
		url: '/manager/sound_status',
		type: 'GET',
		cache: false,
		success: function(status) { jawnosSoundTaskbarRender(status); },
		error: function() { $('#taskbar_sound').attr('hidden', 'hidden').hide(); }
	});
}

$(document).on('click', '#taskbar_sound', function() {
	if (typeof jawnosTaskbarEditing === 'function' && jawnosTaskbarEditing()) { return; }
	if (typeof appWindowOpener === 'function') {
		appWindowOpener('sound', Date.now(), { visible: 'yes' });
	}
});

$(function() {
	setTimeout(jawnosSoundTaskbarLoad, 1600);
	setInterval(jawnosSoundTaskbarLoad, 45000);
});
