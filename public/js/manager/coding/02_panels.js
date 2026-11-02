
// ---- moving the panel, and having more than one -------------------------------
// The header is the handle, exactly as the Guide associate's bar is its handle,
// and the panel is kept on screen and clear of the taskbar. The + in the header
// spawns another agent: a clone with its own mount and conversation, so several
// can be open at once, each remembering its own thread.

var jawnos_coding_agents = 0;
var jawnos_coding_top = 50000;

function codingChatDraggable(panel) {
	if (!panel.length || !$.fn.draggable) { return; }
	panel.draggable({
		revert: 'false',
		handle: '.coding_chat_header',
		cancel: '.coding_chat_new, .coding_chat_close, .coding_chat_stop, .coding_chat_forget, .coding_fixes_toggle, input, button, textarea',
		start: function () {
			// the panel starts anchored right/bottom; give the drag left/top to
			// move, from where it currently sits, so nothing jumps
			var p = $(this);
			var pos = p.position();
			p.css({ right: 'auto', bottom: 'auto', left: pos.left + 'px', top: pos.top + 'px' });
		},
		drag: function (e, ui) {
			// the panel floats over the whole screen, so the screen is what it is
			// kept on - and clear of the taskbar wherever that sits (the same rule
			// the Guide associate's window follows)
			var p = $(this);
			var w = p.outerWidth(), h = p.outerHeight();
			var bar = (typeof jawnosTaskbarHeight === 'function') ? jawnosTaskbarHeight() : 0;
			ui.position.left = Math.max(0, Math.min(ui.position.left, $(window).width() - w));
			ui.position.top = Math.max(panelTopLimit(), Math.min(ui.position.top, $(window).height() - h - bar));
		},
		stop: function () {
			var p = $(this);
			// the clothesline holds the top back on every device
			var top = parseFloat(p.css('top'));
			if (!isNaN(top) && top < panelTopLimit()) { p.css({ 'top': panelTopLimit() + 'px' }); }
			jawnosPanelPosSave('coding:' + (p.attr('conversation') || p.attr('mount')), p);
		}
	});
}

// A panel belongs to its app's window but lives over the whole screen: on the way
// in it is lifted out of the window to the body and positioned against the
// viewport, so it can be dragged anywhere and never clips at the window's edge.
// source_window remembers where it came from - the observer takes the panel away
// when that window is closed.
function codingChatFloat(panel) {
	if (panel.attr('screen_floating')) { return; }
	panel.attr('screen_floating', '1');
	var source = panel.closest('.wind');
	if (source.length && source.attr('id')) { panel.attr('source_window', source.attr('id')); }
	panel.detach().appendTo(document.body);
	panel.css({ position: 'fixed' });
}

function codingChatReap() {
	$('.coding_chat[source_window]').each(function () {
		var id = $(this).attr('source_window');
		if (id && !$('#' + id).length) { $(this).remove(); }
	});
}

// Panels arrive with their app (the window content is fetched), so arm whatever
// is present now and whatever the observer sees appear - the same pattern the
// multiselect upgrade uses. drag_armed keeps it to once per panel.
function codingChatArmAll(root) {
	$(root || document).find('.coding_chat:not([drag_armed])').each(function () {
		var panel = $(this);
		panel.attr('drag_armed', '1');
		codingChatFloat(panel);
		jawnosPanelPosRestore('coding:' + (panel.attr('conversation') || panel.attr('mount')), panel);
		codingChatRestore(panel);
		codingChatReattach(panel);
		codingChatDraggable(panel);
	});
}

function codingChatSpawn(mount, wanted) {
	var src = mount ? codingChatPanel(mount) : $('.coding_chat').first();
	// Re-opening a named conversation must not make a second panel when one is
	// already there (two restore passes can race the terminal's first window).
	if (wanted) {
		var already = $('.coding_chat').filter(function () {
			return ($(this).attr('conversation') || $(this).attr('mount')) === wanted;
		});
		if (already.length) {
			already.first().css({ display: 'flex' });
			return already.first();
		}
	}
	if (!src || !src.length) { return $(); }
	var base = $.trim(src.attr('mount') || 'coding');
	var name = wanted || '';
	if (!name) {
		do {
			jawnos_coding_agents += 1;
			name = base + '_agent_' + jawnos_coding_agents;
		} while ($('#coding_chat_' + name).length);
	}
	var clone = src.clone();
	clone.attr('id', 'coding_chat_' + name).attr('mount', name).attr('conversation', name).attr('spawned', '1');
	clone.removeAttr('drag_armed');
	if (src.attr('source_window')) { clone.attr('source_window', src.attr('source_window')); }
	clone.removeClass('ui-draggable ui-draggable-disabled ui-draggable-handle ui-draggable-dragging');
	clone.find('.coding_chat_title').text($.trim(src.find('.coding_chat_title').text() || 'Coding agent') + (wanted ? '' : ' ' + jawnos_coding_agents));
	clone.find('.coding_chat_log, .coding_fixes_rows').empty();
	clone.find('.coding_fixes_count').text('0');
	clone.find('.coding_fixes_panel').css('display', 'none');
	clone.find('.coding_chat_log').css('display', '');
	clone.find('.coding_chat_composer').css('display', 'flex');
	clone.css({ display: 'flex', position: 'fixed', right: 'auto', bottom: 'auto', left: (24 + jawnos_coding_agents * 26) + 'px', top: (40 + jawnos_coding_agents * 26) + 'px' });
	$(document.body).append(clone);
	codingChatArmAll(document.body);
	if (typeof jawnosAgentOpenRemember === 'function') { jawnosAgentOpenRemember('coding:' + name); }
	clone.find('.coding_chat_input').focus();
	if (wanted) { codingChatHydrate(name); }
	else { codingChatAdd(name, 'step', 'A fresh agent — this one keeps its own thread.'); }
	return clone;
}

function codingChatTitleShow(panel) {
	var t = panel.data('title');
	if (t) { panel.find('.coding_chat_title').text(t); }
}

// Re-open a thread from the agents list: the remembered turns are fetched and
// replayed into the log (action rows and the tool's observations stay out of it).
function codingChatHydrate(mount) {
	var panel = codingChatPanel(mount);
	if (!panel.length) { return; }
	$.get('/manager/agents/thread', { kind: 'coding', name: mount }, function (r) {
		var transcript = (r && r.transcript) || [];
		if (r && r.title) { panel.data('title', r.title); codingChatTitleShow(panel); }
		var shown = 0;
		transcript.forEach(function (m) {
			var role = m.role || 'user';
			var content = String(m.content || '');
			if (role === 'user') { codingChatAdd(mount, 'user', content); shown++; }
			else if (role === 'assistant' && !/^\s*\{/.test(content) && content !== 'done') { codingChatAdd(mount, 'guide', content); shown++; }
		});
		if (!shown) { codingChatAdd(mount, 'step', 'Nothing has been asked here yet.'); }
	});
}

// Open the conversation `name`: a panel already wearing it comes forward; else
// one is made - a clone of any open coding panel, or (with none on screen) the
// terminal is opened first, since that is where a coding panel lives.
function codingChatOpenConversation(name) {
	var existing = $('.coding_chat').filter(function () { return ($(this).attr('conversation') || $(this).attr('mount')) === name; });
	if (existing.length) {
		var panel = existing.first();
		jawnos_coding_top += 1;
		panel.css({ display: 'flex', 'z-index': jawnos_coding_top });
		panel.find('.coding_chat_input').focus();
		return panel;
	}
	if ($('.coding_chat').length) { return codingChatSpawn(null, name); }
	if (typeof appWindowOpener === 'function') {
		appWindowOpener('terminal', Date.now(), { visible: 'yes' });
		var tries = 0;
		var timer = setInterval(function () {
			tries += 1;
			if ($('.coding_chat').length) { clearInterval(timer); codingChatSpawn(null, name); }
			else if (tries > 40) { clearInterval(timer); }
		}, 250);
	}
	return null;
}

$(document).on('click', '.coding_chat_new', function () {
	codingChatSpawn($(this).closest('.coding_chat').attr('mount'));
});
$(document).on('mousedown', '.coding_chat', function () {
	// clicked or grabbed, the panel comes forward - several agents, one stack
	jawnos_coding_top += 1;
	$(this).css('z-index', jawnos_coding_top);
});

$(document).ready(function () { codingChatArmAll(document); });
new MutationObserver(function () { codingChatReap(); codingChatArmAll(document); }).observe(document.documentElement, { childList: true, subtree: true });
