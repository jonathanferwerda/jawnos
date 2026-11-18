// Studio layout: the compact per-track panel, the four hide toggles, floating
// panels and the dynamic track list. The channel state itself still lives in
// mixer[] and studioAudio.channels[]; these helpers only move the existing
// controls around and call the same apply functions.

var STUDIO_MAX_TRACKS = 32;
var studioPanelDrag = null;
var studioLayoutQuiet = false;

function studioLayoutText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

// ---- panels ----------------------------------------------------------------

var studioPanelSelectors = {
	synth: '#studio_synth',
	mixer: '#studio_mixer',
	transport: '#studio_transport_panel',
	tracks: '#studio_tracks_panel'
};

var studioHideSettings = {
	synth: 'hide_synth',
	mixer: 'hide_channel_strips',
	transport: 'hide_transport',
	tracks: 'hide_tracks'
};

function studioPanelElement(name) {
	var selector = studioPanelSelectors[name];
	return selector ? $(selector) : $();
}

// ---- hide / show -----------------------------------------------------------

function studioUpdateHideButton(name, hidden) {
	$('.studio_hide_toggle[data-panel="' + name + '"]').each(function () {
		var button = $(this);
		button.attr('aria-pressed', hidden ? 'true' : 'false');
		var label = hidden ? button.attr('data-show-label') : button.attr('data-hide-label');
		if (label) { button.text(studioLayoutText(label)); }
	});
}

function studioSetPanelHidden(name, hidden, persist) {
	hidden = !!hidden;
	if (name == 'synth') {
		$('.studio_synth_body').toggle(!hidden);
		$('#studio_synth_hide').toggle(!hidden);
		$('#studio_synth_show').toggle(hidden);
	}
	else if (studioPanelSelectors[name]) {
		studioPanelElement(name).toggle(!hidden);
	}
	studioUpdateHideButton(name, hidden);
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	mixer.settings[studioHideSettings[name]] = hidden ? 'yes' : 'no';
	if (persist) {
		studioSaveSettings([{ setting: studioHideSettings[name], value: hidden ? 'yes' : 'no' }]);
	}
}

function studioApplyHideSettings() {
	$.each(studioHideSettings, function (name, setting) {
		var raw = (mixer && mixer.settings) ? mixer.settings[setting] : undefined;
		studioSetPanelHidden(name, String(raw) == 'yes', false);
	});
}

// ---- floating panels -------------------------------------------------------

function studioPersistPanelPosition(name, value) {
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	var setting = 'studio_panel_position_' + name;
	var text = JSON.stringify(value);
	mixer.settings[setting] = text;
	studioSaveSettings([{ setting: setting, value: text }]);
}

function studioClampPanelPosition(panel, left, top) {
	var studio = $('#studio')[0];
	if (!studio) { return { left: left, top: top }; }
	var rect = studio.getBoundingClientRect();
	var width = parseFloat(panel.css('width')) || panel.outerWidth() || 240;
	var height = parseFloat(panel.css('height')) || panel.outerHeight() || 160;
	var maxLeft = Math.max(0, rect.width - width);
	var maxTop = Math.max(0, rect.height - height);
	return {
		left: Math.max(0, Math.min(left, maxLeft)),
		top: Math.max(0, Math.min(top, maxTop))
	};
}

function studioFloatPanel(name, position, persist) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return panel; }
	if (!panel.hasClass('studio_panel_floating')) {
		var rect = panel[0].getBoundingClientRect();
		var studioRect = $('#studio')[0].getBoundingClientRect();
		panel.data('studio-home-parent', panel.parent()[0] || $('#studio')[0]);
		panel.data('studio-home-next', panel.next()[0] || null);
		panel.addClass('studio_panel_floating');
		panel.css({
			left: Math.max(0, rect.left - studioRect.left) + 'px',
			top: Math.max(0, rect.top - studioRect.top) + 'px'
		});
		if (rect.width > 20) { panel.css('width', rect.width + 'px'); }
		if (name != 'synth' && rect.height > 20) { panel.css('height', rect.height + 'px'); }
		$('#studio').append(panel);
	}
	if (position && typeof position.left == 'number' && typeof position.top == 'number') {
		var clamped = studioClampPanelPosition(panel, position.left, position.top);
		panel.css({ left: clamped.left + 'px', top: clamped.top + 'px' });
	}
	if (persist) {
		studioPersistPanelPosition(name, {
			left: parseFloat(panel.css('left')) || 0,
			top: parseFloat(panel.css('top')) || 0
		});
	}
	return panel;
}

function studioDockPanel(name) {
	var panel = studioPanelElement(name);
	if (!panel.length || !panel.hasClass('studio_panel_floating')) { return; }
	var parent = panel.data('studio-home-parent');
	var next = panel.data('studio-home-next');
	panel.removeClass('studio_panel_floating studio_panel_dragging')
		.css({ left: '', top: '', width: '', height: '', position: '' });
	if (parent && $.contains(document.documentElement, parent)) {
		if (next && next.parentNode === parent) { $(next).before(panel); }
		else { $(parent).append(panel); }
	}
	else { $('#studio').append(panel); }
	studioPersistPanelPosition(name, { docked: true });
}

function studioApplyPanelPositions() {
	$.each(studioPanelSelectors, function (name) {
		var raw = (mixer && mixer.settings) ? mixer.settings['studio_panel_position_' + name] : undefined;
		if (!raw) { return; }
		var position = null;
		try { position = JSON.parse(raw); } catch (e) { return; }
		if (!position) { return; }
		if (position.docked) { studioDockPanel(name); }
		else if (typeof position.left == 'number' && typeof position.top == 'number') {
			studioFloatPanel(name, position, false);
		}
	});
}

// A window can be smaller than the desk it was floated on; pull a saved panel
// back so at least its own box stays inside the Studio window.
$(window).on('resize', function () {
	$('.studio_panel_floating').each(function () {
		var panel = $(this);
		var position = studioClampPanelPosition(panel,
			parseFloat(panel.css('left')) || 0, parseFloat(panel.css('top')) || 0);
		panel.css({ left: position.left + 'px', top: position.top + 'px' });
	});
});

function studioApplyLayoutSettings() {
	// Positions first: a panel that is about to be hidden has no size to measure.
	studioApplyPanelPositions();
	studioApplyHideSettings();
	studioUpdateTrackCount();
}

// A pointer drag moves a floating panel; pressing the handle on a docked panel
// detaches it at its current place first, so the drag begins where you grabbed.
$(document).on('pointerdown', '.studio_drag_handle', function (e) {
	if (e.originalEvent && e.originalEvent.button) { return; }
	var name = $(this).attr('data-studio-drag');
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	studioFloatPanel(name);
	var studioRect = $('#studio')[0].getBoundingClientRect();
	var rect = panel[0].getBoundingClientRect();
	studioPanelDrag = {
		name: name,
		panel: panel,
		dx: e.originalEvent.clientX - rect.left,
		dy: e.originalEvent.clientY - rect.top
	};
	panel.addClass('studio_panel_dragging');
	try { this.setPointerCapture(e.originalEvent.pointerId); } catch (err) {}
	e.preventDefault();
});

$(document).on('pointermove', function (e) {
	if (!studioPanelDrag) { return; }
	var studioRect = $('#studio')[0].getBoundingClientRect();
	var left = e.originalEvent.clientX - studioRect.left - studioPanelDrag.dx;
	var top = e.originalEvent.clientY - studioRect.top - studioPanelDrag.dy;
	var clamped = studioClampPanelPosition(studioPanelDrag.panel, left, top);
	studioPanelDrag.panel.css({ left: clamped.left + 'px', top: clamped.top + 'px' });
	e.preventDefault();
});

$(document).on('pointerup pointercancel', function () {
	if (!studioPanelDrag) { return; }
	var drag = studioPanelDrag;
	studioPanelDrag = null;
	drag.panel.removeClass('studio_panel_dragging');
	studioPersistPanelPosition(drag.name, {
		left: parseFloat(drag.panel.css('left')) || 0,
		top: parseFloat(drag.panel.css('top')) || 0
	});
});

$(document).on('click', '.studio_hide_toggle', function () {
	var name = $(this).attr('data-panel');
	var hidden = $(this).attr('aria-pressed') == 'true';
	studioSetPanelHidden(name, !hidden, true);
});

$(document).on('click', '.studio_float_toggle', function () {
	var name = $(this).attr('data-panel');
	var panel = studioPanelElement(name);
	if (panel.hasClass('studio_panel_floating')) { studioDockPanel(name); }
	else { studioFloatPanel(name, null, true); }
});

$(document).on('click', '.studio_dock', function () {
	studioDockPanel($(this).attr('data-panel'));
});

// The synth keeps its own Hide/Show buttons; they also remember the choice.
$(document).on('click', '#studio_synth_hide', function () { studioSetPanelHidden('synth', true, true); });
$(document).on('click', '#studio_synth_show', function () { studioSetPanelHidden('synth', false, true); });

$(document).on('click', '#studio_pedalboard_close', function () {
	$('#pedalboard').hide();
});

// ---- the dynamic track list ------------------------------------------------

// Binding the pedal drop on a strip or a per-track panel. The channel number is
// the class suffix on a strip and the channel attribute on a track panel.
function studioBindChannelDrop(node) {
	node.droppable({
		accept: '.pedal_background',
		tolerance: 'pointer',
		drop: function (event, ui) {
			var name = ui.draggable.attr('hint');
			var m = (String($(this).attr('class')) || '').match(/channel_(\d+)/);
			var ch = m ? m[1] : $(this).attr('channel');
			if (!name || !ch) { return; }
			var channel = studioAudio.channels[ch];
			studioSetInsert(ch, name, !(channel && channel.insertByName[name]));
			studioSaver();
		}
	});
}

function studioTrackNumbers() {
	var numbers = [];
	$('#studio_viewer .studio_track').each(function () {
		var n = parseInt($(this).attr('data-channel'), 10);
		if (n > 0) { numbers.push(n); }
	});
	numbers.sort(function (a, b) { return a - b; });
	return numbers;
}

function studioNextTrackNumber() {
	for (var n = 1; n <= STUDIO_MAX_TRACKS; n++) {
		if (!document.getElementById('studio_track_row_' + n)) { return n; }
	}
	return 0;
}

function studioUpdateTrackCount() {
	var count = studioTrackNumbers().length;
	$('#studio_viewer').attr('channel_count', count);
	$('#studio_track_count').text(count + ' / ' + STUDIO_MAX_TRACKS);
}

function studioSaveTrackCount() {
	var count = studioTrackNumbers().length;
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	mixer.settings['channel_count'] = String(count);
	studioSaveSettings([{ setting: 'channel_count', value: String(count) }]);
	studioUpdateTrackCount();
}

// Rewrite the channel number a cloned row or strip carries.
function studioRewireChannel(node, from, to) {
	from = String(from);
	to = String(to);
	if (from == to) { return node; }
	var classRe = new RegExp('_' + from + '\\b', 'g');
	var idRe = new RegExp('_' + from + '$');
	node.find('[channel]').addBack('[channel]').each(function () {
		if (String($(this).attr('channel')) == from) { $(this).attr('channel', to); }
	});
	node.find('[data-channel]').addBack('[data-channel]').each(function () {
		if (String($(this).attr('data-channel')) == from) { $(this).attr('data-channel', to); }
	});
	node.find('[id]').addBack('[id]').each(function () {
		if (this.id) { this.id = this.id.replace(idRe, '_' + to); }
	});
	node.find('[class]').addBack('[class]').each(function () {
		this.className = String(this.className).replace(classRe, '_' + to);
	});
	return node;
}

function studioResetChannelMarkup(node, ch) {
	node.find('.armed').attr('state', 'off').text('O');
	node.find('.channel_volume').val(1);
	node.find('.channel_fx').empty().removeClass('studio_fx_open');
	node.find('.studio_channel_information').text('');
	node.find('.knob_control').val(50);
	node.find('.knob').css('transform', '');
	node.find('.studio_track_name').val(studioLayoutText('Track') + ' ' + ch);
	node.find('.studio_track_automation').attr('aria-pressed', 'false');
	node.removeClass('selected_channel studio_track_automation_on studio_fx_open');
	node.find('.selected_channel').removeClass('selected_channel');
	node.find('canvas').each(function () { this.width = 0; this.height = 0; });
	var resetVideo = function () {
		this.removeAttribute('src');
		this.srcObject = null;
		this.style.display = 'none';
	};
	node.filter('video').each(resetVideo);
	node.find('video').each(resetVideo);
}

function studioCreateTrack(ch) {
	ch = parseInt(ch, 10);
	if (!(ch > 0 && ch <= STUDIO_MAX_TRACKS)) { return null; }
	if (document.getElementById('studio_track_row_' + ch)) { return ch; }
	var rowTemplate = $('#studio_viewer .studio_track').first();
	var stripTemplate = $('#studio_mixer_strips .channel').first();
	if (!rowTemplate.length || !stripTemplate.length) { return null; }
	var from = parseInt(rowTemplate.attr('data-channel'), 10) || 1;
	var stripFrom = parseInt((String(stripTemplate.attr('class')).match(/channel_(\d+)/) || [])[1], 10) || from;

	var wasQuiet = studioLayoutQuiet;
	studioLayoutQuiet = true;
	var row = studioRewireChannel(rowTemplate.clone(), from, ch);
	var strip = studioRewireChannel(stripTemplate.clone(), stripFrom, ch);
	studioResetChannelMarkup(row, ch);
	studioResetChannelMarkup(strip, ch);
	var monitorTemplate = $('#studio_video_monitors video').first();
	var monitor = $();
	if (monitorTemplate.length) {
		var monitorFrom = parseInt((String(monitorTemplate.attr('id')).match(/_(\d+)$/) || [])[1], 10) || from;
		monitor = studioRewireChannel(monitorTemplate.clone(), monitorFrom, ch);
		studioResetChannelMarkup(monitor, ch);
		monitor.attr('id', 'studio_video_monitor_' + ch).hide();
	}

	$('#studio_viewer').append(row);
	$('#studio_mixer_strips').append(strip);
	if (monitor.length) { $('#studio_video_monitors').append(monitor); }

	// keep the list in channel order even when a gap is filled
	studioPlaceTrackRow(row, ch, '#studio_viewer');
	studioPlaceTrackRow(strip, ch, '#studio_mixer_strips');
	studioBindChannelDrop(row.find('.studio_track_panel'));
	studioBindChannelDrop(strip);

	if (!mixer[ch]) { mixer[ch] = {}; }
	if (!mixer[ch].media) { mixer[ch].media = { out: [], rec: [] }; }
	if (!mixer[ch].armed) { mixer[ch].armed = { state: 'off', text: 'O' }; }
	studioChannelEngine(ch);
	studioApplyChannel(ch);
	$('.knob_control[channel="' + ch + '"]').trigger('change');
	studioDrawChannel(ch);
	studioLayoutQuiet = wasQuiet;
	studioUpdateTrackCount();
	return ch;
}

function studioAddTrack() {
	var ch = studioNextTrackNumber();
	if (!ch) { return; }
	if (studioCreateTrack(ch)) {
		studioSaveTrackCount();
		studioSaver();
	}
}

function studioEnsureTracks(count) {
	count = Math.min(Math.max(parseInt(count, 10) || 0, 0), STUDIO_MAX_TRACKS);
	for (var ch = 1; ch <= count; ch++) {
		if (!document.getElementById('studio_track_row_' + ch)) { studioCreateTrack(ch); }
	}
	studioUpdateTrackCount();
}

function studioEnsureTracksForSong(song) {
	var highest = 0;
	$.each(song || {}, function (key) {
		if (/^[0-9]+$/.test(key)) {
			var n = parseInt(key, 10);
			if (n > highest) { highest = n; }
		}
	});
	if (highest) { studioEnsureTracks(highest); }
}

// Move a freshly cloned row or strip into channel order.
function studioPlaceTrackRow(node, ch, container) {
	var placed = false;
	$(container).children().each(function () {
		var other = parseInt($(this).attr('data-channel'), 10);
		if (!other) {
			var m = String($(this).attr('class') || '').match(/channel_(\d+)/);
			other = m ? parseInt(m[1], 10) : 0;
		}
		if (other > ch) { $(this).before(node); placed = true; return false; }
	});
	if (!placed) { $(container).append(node); }
}

// A loaded song owns its track list: build what it needs and drop the rows the
// previous song left behind. Quiet, because this is not a user edit.
function studioSyncTrackList(song) {
	var wanted = {};
	$.each(song || {}, function (key) {
		if (/^[0-9]+$/.test(key)) { wanted[String(key)] = true; }
	});
	if (!Object.keys(wanted).length) { return; }
	studioEnsureTracksForSong(song);
	var wasQuiet = studioLayoutQuiet;
	studioLayoutQuiet = true;
	studioTrackNumbers().forEach(function (ch) {
		if (!wanted[String(ch)]) { studioRemoveTrack(ch, true); }
	});
	studioLayoutQuiet = wasQuiet;
	studioUpdateTrackCount();
}

function studioRemoveTrack(ch, quiet) {
	ch = String(ch);
	if (studioTrackNumbers().length <= 1) {
		$('.studio_track_delete[channel="' + ch + '"]').attr('armed', 'no').css('background-color', '');
		return;
	}
	var media = mixer[ch] && mixer[ch].media;
	if (media && media.rec) {
		$.each(media.rec, function (i, recorder) {
			if (recorder && recorder.state && recorder.state != 'inactive') {
				try { recorder.stop(); } catch (e) {}
			}
		});
	}
	var channel = studioAudio.channels[ch];
	if (channel) {
		['trim', 'bass', 'mid', 'treble', 'recGain', 'recAnalyser', 'recDest', 'playBus', 'playPan', 'monGain'].forEach(function (key) {
			if (channel[key] && channel[key].disconnect) {
				try { channel[key].disconnect(); } catch (e) {}
			}
		});
		(channel.inserts || []).forEach(function (insert) {
			if (insert.destroy) { try { insert.destroy(); } catch (e) {} }
		});
	}
	delete studioAudio.channels[ch];
	delete mixer[ch];
	$('#studio_track_row_' + ch).remove();
	$('#studio_mixer_strips .channel_' + ch).remove();
	$('#studio_video_monitor_' + ch).remove();
	$('#studio_track_container .studio_video[id^="studio_channel_' + ch + '_"]').remove();
	if (String(studioSelectedChannel) == ch) {
		var left = studioTrackNumbers();
		studioSelectedChannel = left.length ? left[0] : 0;
	}
	studioTakesChanged();
	studioUpdateTrackCount();
	if (!quiet) {
		studioSaveTrackCount();
		studioSaver();
	}
}

$(document).on('click', '#studio_add_track', function () { studioAddTrack(); });

$(document).on('click', '.studio_track_delete', function () {
	var button = $(this);
	if (button.attr('armed') != 'yes') {
		button.attr('armed', 'yes').css({ 'background-color': 'red' });
		clearTimeout(button.data('studioDeleteTimer'));
		button.data('studioDeleteTimer', setTimeout(function () {
			button.attr('armed', 'no').css({ 'background-color': '' });
		}, 2000));
		return;
	}
	studioRemoveTrack(button.attr('channel'));
});

$(document).on('change', '.studio_track_name', function () {
	var ch = $(this).attr('channel');
	if (!/^[0-9]+$/.test(ch)) { return; }
	if (!mixer[ch]) { mixer[ch] = {}; }
	mixer[ch].name = $(this).val();
	studioSaver();
});

$(document).on('click', '.studio_track_automation', function () {
	var button = $(this);
	var ch = button.attr('channel');
	var on = button.attr('aria-pressed') != 'true';
	button.attr('aria-pressed', on ? 'true' : 'false');
	$('#studio_track_row_' + ch).toggleClass('studio_track_automation_on', on);
	if (!mixer[ch]) { mixer[ch] = {}; }
	mixer[ch].automation_view = on ? 1 : 0;
	studioSaver();
});

$(document).on('click', '.studio_track_fx', function () {
	var ch = $(this).attr('channel');
	var badge = $('.channel_fx[channel="' + ch + '"]');
	badge.toggleClass('studio_fx_open');
	if (badge.hasClass('studio_fx_open') && !$('#pedalboard').is(':visible')) {
		$('#pedalboard').show();
		var z = numeral($('#studio_viewer').closest('.wind').css('z-index')).value() || 0;
		$('#pedalboard').css({ 'z-index': (z + 100) });
	}
});
