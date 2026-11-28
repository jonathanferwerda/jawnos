// ---- the associate as a conversationalist ---------------------------------
// The same switch the help window's guide has: with a conversation on, the mic
// opens again after each answer, the clip ends itself once the person stops
// talking, and each utterance is the next turn of this panel's own thread -
// until "bye jawn" or the End button. The button says which it is: with the
// box empty it reads Converse, with words typed it reads Ask, and while a
// conversation runs it reads End.
function assistantTalking(panel) { return panel.attr('talking') === 'yes'; }

function assistantButtonLabel(panel) {
	var b = panel.find('.assistant_send');
	if (!b.length) { return; }
	var q = $.trim(panel.find('.assistant_question').val() || '');
	if (q) { b.text('Ask').css({ 'border-color': 'var(--line)', 'color': '' }).attr('hint', 'Ask, or ask it to do it'); }
	else if (assistantTalking(panel)) { b.text('End').css({ 'border-color': '#e23b3b', 'color': '#e23b3b' }).attr('hint', 'End the conversation'); }
	else { b.text('Converse').css({ 'border-color': 'var(--line)', 'color': '' }).attr('hint', 'Start a spoken conversation: the mic opens again after each answer, so you can just keep talking — say “bye jawn” or press End to stop'); }
}

function assistantConversationOn(panel) {
	if (assistantTalking(panel)) { return; }
	panel.attr('talking', 'yes');
	// a new conversation reads the room afresh
	if (typeof jawnRoomReset === 'function') { jawnRoomReset(); }
	assistantButtonLabel(panel);
	assistantChatAdd(panel, 'step', 'Conversation on — I will keep listening after each answer. Press End or say “bye jawn” to stop.');
}

function assistantConversationEnd(panel) {
	if (!assistantTalking(panel)) { return; }
	panel.removeAttr('talking');
	if (typeof jawn_clip !== 'undefined' && jawn_clip.owner && jawn_clip.owner === panel[0]) { jawnClipStop(true); }
	// the phone's own recogniser, if this panel's turn was on it, stops too
	if (typeof jawnSpeechOemStop === 'function') {
		var oem = panel.data('oem_owner');
		if (oem) { jawnSpeechOemStop(oem); panel.removeData('oem_owner'); }
	}
	assistantButtonLabel(panel);
	assistantChatAdd(panel, 'guide', 'Alright — I will be here.');
}

// The service the associate's composer resolved to on the server
// (transcription_guide, or the shared role). android:oem means the phone's own
// recogniser may answer the microphone instead of the recorder.
function assistantTranscriptionService(panel) {
	var box = panel.find('.assistant_question');
	return (box && box.attr) ? (box.attr('data-transcribe-service') || '') : '';
}

function assistantConversationListen(panel, spoken) {
	if (!assistantTalking(panel)) { return; }
	var begin = function () {
		setTimeout(function () {
			if (!assistantTalking(panel)) { return; }
			// The recorder path, unchanged: used when the Guide's role is not the
			// phone's recogniser, and whenever that recogniser cannot start.
			var listen_browser = function () {
				if (typeof jawnClipListen !== 'function') { return; }
				jawnClipListen({
					talking: true,
					owner: panel[0],
					selfWords: assistantLastWords(panel),
					status: function (msg) { assistantChatAdd(panel, 'step', msg); },
					onText: function (text) { assistantConversationHeard(panel, text); },
					onEcho: function () { assistantConversationListen(panel); },
					onFail: function (reason) {
						if (!assistantTalking(panel)) { return; }
						// a deaf microphone ends it; anything else just listens again
						if (reason === 'microphone' || reason === 'no microphone') { assistantConversationEnd(panel); return; }
						assistantConversationListen(panel);
					}
				});
			};
			var service = assistantTranscriptionService(panel);
			if (typeof jawnSpeechOemReady === 'function' && jawnSpeechOemReady(service)) {
				// The phone's recogniser returns text, not audio: no audio clip for Plat,
				// no punctuation pass and no clip kept. The final phrase reaches the
				// same callback the recorder's transcript uses.
				var owner = {
					lang: String(window.jawnos_lang_code || 'en-US'),
					restart: false,
					onPartial: function (text) {
						if (!text) { return; }
						if (typeof assistantLastWords === 'function' && assistantLastWords(panel)) { return; }
						var box = panel.find('.assistant_question');
						if (box && box.length) { box.val(text); }
					},
					onFinal: function (text) {
						jawnSpeechOemStop(owner);
						panel.removeData('oem_owner');
						var self_words = assistantLastWords(panel);
						var verdict = (self_words && typeof jawnEchoCheck === 'function')
							? jawnEchoCheck(text, self_words)
							: { echo: false, text: text };
						if (verdict.echo) { if (assistantTalking(panel)) { assistantConversationListen(panel); } return; }
						assistantConversationHeard(panel, verdict.text);
					},
					onError: function () {
						// the phone could not hear: finish this turn with the recorder
						if (!assistantTalking(panel)) { return; }
						panel.removeData('oem_owner');
						listen_browser();
					}
				};
				panel.data('oem_owner', owner);
				if (jawnSpeechOemStart(owner)) { return; }
				panel.removeData('oem_owner');
			}
			listen_browser();
		}, 350);
	};
	if (spoken && spoken.done) {
		// the reply is being said aloud: hold the mic until the voice is done
		spoken.done(function (r) {
			var secs = parseFloat((r && r.seconds) || 0) || 0;
			setTimeout(function () { if (assistantTalking(panel)) { begin(); } }, Math.min(30000, 1000 * secs));
		});
		spoken.fail(function () { begin(); });
	}
	else { begin(); }
}

// the panel's own last words, so a conversation's mic can tell the speaker from
// the person
function assistantLastWords(panel) {
	var t = (typeof assistantThread === 'function') ? assistantThread(panel) : [];
	for (var i = t.length - 1; i >= 0; i--) {
		var m = t[i] || {};
		if ((m.role || '') === 'assistant' && m.content && !/^\s*\{/.test(m.content)) { return m.content; }
	}
	return '';
}

function assistantConversationHeard(panel, text) {
	if (!assistantTalking(panel)) { return; }
	var q = $.trim(text || '');
	if (!q) { assistantConversationListen(panel); return; }
	if (helpConversationBye(q)) { assistantConversationEnd(panel); return; }
	panel.find('.assistant_question').val('');
	assistantButtonLabel(panel);
	assistantOpenPanel(panel);
	assistantChatAdd(panel, 'user', q);
	assistantRemember(panel, 'user', q);
	assistantGuideStep(panel, 0);
}

// A dropped picture (or voice clip) goes to the assistant; its answer streams
// into the chat bubble the same way the mailbox one does.
function assistantDrop(panel, media) {
	media = media || {};
	assistantOpenPanel(panel);
	if (media.image) {
		var log = assistantLog(panel);
		log.append($('<div style="display:flex;margin:4px 0;justify-content:flex-end;">'
			+ '<span style="display:inline-block;max-width:84%;border-radius:10px;padding:5px;background:var(--chat-bubble-me);">'
			+ '<img style="display:block;max-width:180px;max-height:180px;border-radius:6px;" src="' + media.image + '"></span></div>'));
		log.scrollTop(log[0].scrollHeight);
		assistantRemember(panel, 'user', '(I showed you a picture)');
	}
	else if (media.audio) {
		assistantChatAdd(panel, 'user', '(voice clip)');
		assistantRemember(panel, 'user', '(I played you a voice clip)');
	}
	var content = assistantAnswerBubble(panel);
	$.ajax({
		url: '/manager/assistant',
		type: 'POST',
		data: { image: media.base64, audio: media.audio },
		success: function (response) {
			if (response && response.uuid) { content.attr('uuid', response.uuid); }
			content.text('…');
		},
		error: function () { content.text('I could not reach the assistant.'); }
	});
}

// What the assistant was dragged onto, spelled out for the guide: the element,
// any hint or id it carries, and the app or window it lives in.
function assistantDescribeElement(el) {
	var $e = $(el);
	if (!$e.length || el === document.body || el === document.documentElement) { return ''; }
	var bits = [];
	bits.push((el.tagName || '').toLowerCase());
	if ($e.attr('id')) { bits.push('#' + $e.attr('id')); }
	if (typeof el.className == 'string' && el.className.trim()) { bits.push('.' + el.className.trim().split(/\s+/).slice(0, 3).join('.')); }
	var hint = $e.attr('hint') || $e.attr('title') || $e.attr('aria-label') || $e.attr('placeholder');
	if (hint) { bits.push('(hint: ' + hint + ')'); }
	var label = $.trim($e.closest('label').text());
	if (label) { bits.push('label: "' + label.slice(0, 60) + '"'); }
	var app = assistantAppFor(el);
	if (app) { bits.push('app: "' + app + '"'); }
	var win = $.trim($e.closest('.wind').find('.name_text').first().text());
	if (win) { bits.push('window: "' + win + '"'); }
	var text = $.trim($e.text()).slice(0, 80);
	if (text) { bits.push('text: "' + text + '"'); }
	return bits.join(' ');
}

// The app a control belongs to: the window or shortcut it sits in, or the app a
// start-menu icon opens (the menu's own map, so a reworded hint or a translated
// label cannot lose it). '' when the element names none.
function assistantAppFor(el) {
	var $e = $(el);
	var app = $e.closest('[app]').attr('app') || '';
	if (!app && typeof startMenuIconApps !== 'undefined') {
		// the menu wraps each icon in a row, so the row itself names no app
		var icons = $e.closest('.start_menu_item').find('img[id]');
		icons.each(function () {
			if (!app && startMenuIconApps[this.id]) { app = startMenuIconApps[this.id]; }
		});
		var id = $e.closest('[id]').attr('id') || '';
		if (!app && id && startMenuIconApps[id]) { app = startMenuIconApps[id]; }
	}
	return app || '';
}

// An app icon is an <img> too, so the tag cannot tell a picture the person wants
// looked at from a piece of the program they want explained. The program's own
// drawings give themselves away: a hint (what the control does), a title, an
// ARIA label, the `help` topic the Help app reads, a button around them, or the
// menu, taskbar, desk-shortcut, window-button and icon classes they wear. A
// plain image - a photo, a chart, a drawing - carries none of those and is
// looked at. The `_thumb` classes are sizing only (a shop's photograph and an
// attachment preview wear them too), so they say nothing either way.
function assistantImageIsControl(el) {
	var $e = $(el);
	if (!$e.length || (el.tagName || '').toLowerCase() !== 'img') { return false; }
	// the picture may be the control itself (an icon with a hint or a label) ...
	if ($e.is('[hint], [title], [aria-label], [help]')) { return true; }
	// ... or sit inside one, or in the menu, taskbar, desk or window button. An
	// ancestor's title or aria-label alone is not enough: a folder listing's
	// contents carry one, and a photograph inside it is still a photograph.
	if ($e.closest('[hint], [help], button, [role="button"], #start_menu, .start_menu_item, .taskbar_pin, .desk_app, .desk_place, .window_toggle').length) { return true; }
	var cls = (typeof el.className === 'string') ? el.className : '';
	return /(^|\s)(jonathan|draggable|start_menu_corner|[\w-]+_icon|[\w-]+_toggle)(\s|$)/.test(cls);
}

// Dropped onto a control or a window (not a picture): ask the guide about it,
// carrying the thread on so it remembers what came before.
function assistantHelpFor(panel, el) {
	var desc = assistantDescribeElement(el);
	assistantOpenPanel(panel);
	if (!desc) {
		assistantChatAdd(panel, 'step', 'Drop me onto a control or a window and I will explain it.');
		return;
	}
	// the element may name a help topic; hand it over so the guide has the briefing
	panel.data('topic', $(el).closest('[help]').attr('help') || assistantAppFor(el));
	assistantChatAdd(panel, 'user', 'Help me with: ' + desc);
	assistantRemember(panel, 'user', 'The person dragged me onto this element and wants help using it: ' + desc);
	assistantGuideStep(panel, 0);
}

$(document).on('click', '.assistant_send', function () { assistantAsk($(this).closest('.assistant_view')); });
$(document).on('input', '.assistant_question', function () { if (typeof assistantButtonLabel === 'function') { assistantButtonLabel($(this).closest('.assistant_view')); } });
$(function () { $('.assistant_view').each(function () { assistantButtonLabel($(this)); }); });
$(document).on('keydown', '.assistant_question', function (e) {
	if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); assistantAsk($(this).closest('.assistant_view')); }
});
$(document).on('click', '.assistant_new', function () { assistantSpawn($(this).closest('.assistant_view')); });
// A spawned associate is nobody's layout: closing it removes it (manager.js),
// and this delegated press also drops it from the browser's remembered panels
// (agents.js). A close is not a delete - the thread stays on the server - so it
// simply stops coming back on the next reload. manager.js may already have
// detached the panel by the time this runs; the detached subtree keeps its
// attributes, so closest() still names the conversation.
$(document).on('click', '.assistant_close', function () {
	var panel = $(this).closest('.assistant_view');
	if (!panel.attr('spawned')) { return; }
	var name = panel.attr('conversation');
	if (!name) { return; }
	if (typeof jawnosAgentOpenForget === 'function') { jawnosAgentOpenForget('guide:' + name); }
});
$(document).on('mousedown', '.assistant_view', function () { jawnos_assistant_last = $(this); });
$(document).on('click', '#assistant', function () {
	if (jawnos_assistant_dragging) { return; }
	// wait out a second press: a double-press asks for the agents list (agents.js),
	// and only a lone press should open the chat panel itself
	clearTimeout(jawnos_assistant_click_timer);
	jawnos_assistant_click_timer = setTimeout(function () { assistantOpen(); }, 260);
});

// Another associate: a clone of an open one, with its own conversation name and
// thread. Spawned panels are taken away by their close; the taskbar's own stays.
// A reopened spawn is assistantOpenConversation materialising a named thread: it
// is not remembered under the throwaway name this function invents (that name
// is not a conversation a reload should open).
function assistantSpawn(source, reopened) {
	source = (source && source.length) ? source : $('.assistant_view').first();
	if (!source.length) { return $(); }
	var name;
	do {
		jawnos_assistant_extra += 1;
		name = 'assistant_' + jawnos_assistant_extra;
	} while ($('.assistant_view[conversation="' + name + '"]').length);
	var clone = source.clone();
	clone.attr('id', '').attr('conversation', name).attr('spawned', '1');
	clone.data('thread', []).data('greeted', 0).data('title', '');
	clone.removeData('page_app');
	clone.removeData('page_window');
	clone.removeData('page_on');
	clone.find('.assistant_page_badge').hide();
	clone.find('.assistant_chat_log').empty();
	clone.find('.assistant_staged_panel').hide();
	clone.find('.assistant_chat_log, .assistant_input_row').show();
	clone.find('.assistant_config_menu').hide();
	clone.find('.assistant_title').text('Guide\'s associate ' + jawnos_assistant_extra);
	clone.removeAttr('drag_armed');
	clone.find('.assistant_anchor').removeAttr('icon_armed').removeClass('ui-draggable ui-draggable-disabled ui-draggable-handle ui-draggable-dragging');
	var off = (jawnos_assistant_extra % 6) * 26;
	clone.css({ display: 'none', right: '', bottom: '', left: Math.max(6, (source.offset().left || 40) + 30 + off) + 'px', top: Math.max(6, (source.offset().top || 40) + 30 + off) + 'px' });
	$(document.body).append(clone);
	// the browser remembers a spawned panel, so a reload can put it back (agents.js)
	if (!reopened && typeof jawnosAgentOpenRemember === 'function') { jawnosAgentOpenRemember('guide:' + name); }
	assistantInitializer();
	assistantButtonLabel(clone);
	clone.find('.assistant_question').focus();
	assistantChatAdd(clone, 'step', 'A fresh associate — this one keeps its own thread.');
	assistantOpenPanel(clone);
	return clone;
}

// Re-open a conversation from the agents list (or start its panel if none is
// open): the remembered turns are fetched and replayed into the log.
function assistantOpenConversation(name, title, question) {
	var existing = $('.assistant_view[conversation="' + name + '"]');
	if (existing.length) {
		var open = assistantOpenPanel(existing.first());
		if (question) {
			open.find('.assistant_question').val(question);
			if (typeof assistantAsk === 'function') { assistantAsk(open); }
		}
		return open;
	}
	var panel = assistantSpawn($('.assistant_view').first(), 1);
	if (!panel.length) { return panel; }
	panel.attr('conversation', name).data('title', title || '').data('greeted', 1);
	panel.find('.assistant_chat_log').empty();
	panel.data('thread', []);
	assistantTitleShow(panel);
	$.get('/manager/agents/thread', { kind: 'guide', name: name }, function (r) {
		var transcript = (r && r.transcript) || [];
		panel.data('thread', transcript);
		if (r && r.title) { panel.data('title', r.title); assistantTitleShow(panel); }
		var log = assistantLog(panel);
		if (!transcript.length) { assistantChatAdd(panel, 'step', 'Nothing was said here yet.'); }
		else {
			var shown = 0;
			transcript.forEach(function (m) {
				var role = m.role || 'user';
				var content = String(m.content || '');
				if (role === 'user') { assistantChatAdd(panel, 'user', content); shown++; }
				else if (role === 'assistant' && !/^\s*\{/.test(content)) { assistantChatAdd(panel, 'guide', content); shown++; }
			});
			if (!shown) { assistantChatAdd(panel, 'step', 'Nothing was said here yet.'); }
		}
		log.scrollTop(log[0] ? log[0].scrollHeight : 0);
		if (question) {
			panel.find('.assistant_question').val(question);
			if (typeof assistantAsk === 'function') { assistantAsk(panel); }
		}
	});
	return panel;
}

// The window is armed once per panel: it drags by its header, and every panel
// wears the same classes, so one arm covers the ones spawned later too.
function assistantInitializer() {
	$('.assistant_view:not([drag_armed])').each(function () {
		var panel = $(this);
		panel.attr('drag_armed', '1');
		panel.draggable({
			revert: 'false',
			handle: '.assistant_header',
			// a few pixels of travel before a drag begins (with the touch threshold in
			// touch-threshold.js), so a tap never moves the panel
			distance: 8,
			cancel: '.assistant_anchor, .assistant_new, .assistant_close, .assistant_config, .assistant_confirm, .assistant_confirm_delete, .assistant_staged_open, input, button, label, textarea',
			drag: function (e, ui) {
				// keep the panel on screen and clear of the taskbar, wherever it is dragged
				var w = $(this).outerWidth(), h = $(this).outerHeight();
				var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
				ui.position.left = Math.max(0, Math.min(ui.position.left, $(window).width() - w));
				ui.position.top = Math.max(panelTopLimit(), Math.min(ui.position.top, $(window).height() - h - bar));
			},
			stop: function () {
				// the clothesline holds the top back on every device
				var p = $(this);
				var top = parseFloat(p.css('top'));
				if (!isNaN(top) && top < panelTopLimit()) { p.css({ 'top': panelTopLimit() + 'px' }); }
				jawnosPanelPosSave('guide:' + (p.attr('conversation') || 'assistant'), p);
			}
		});
		if (typeof jawnosPanelResizable == 'function') {
			jawnosPanelResizable(panel, function (p) { return 'guide:' + (p.attr('conversation') || 'assistant'); });
		}
	});

	assistantIconInitializer();
}

// The assistant's own button rides in the start menu, which the socket fetches
// anew on every open, so the drag is armed once at load for the copy the page
// ships with and again over there after each fetch.
function assistantIconInitializer() {
	// the start-menu button, its taskbar pin, and each panel's own corner icon:
	// drag any of them onto something and the guide looks at whatever is under
	// the pointer (the panels' copies are excluded from the panel-move handle
	// above). Armed once per element - the taskbar re-lays its pins and the
	// start menu refetches, so a fresh copy arrives unarmed.
	$('#assistant:not([icon_armed]), .assistant_anchor:not([icon_armed]), .taskbar_pin[sel$="#assistant"]:not([icon_armed])').each(function () {
		$(this).attr('icon_armed', '1');
		$(this).draggable({
			appendTo: "body",
			helper: "clone",
			revert: "invalid",
			zIndex: 999999,
			cursorAt: { top: 30, left: 30 },
			// the button is both a tap (open the associate) and a drag (drop it on a
			// picture): a little travel before a drag begins keeps a tap a tap (with the
			// touch threshold in touch-threshold.js)
			distance: 10,
			cancel: '',
			start: function(p,ui) {
				jawnos_assistant_dragging = true;
			},
			drag: function(p,ui) {
			  ui.position.left = p.pageX - 30;
			  ui.position.top = p.pageY - 30;
			},
			stop: function(p,ui) {
			setTimeout(function () { jawnos_assistant_dragging = false; }, 0);
			$(this).css('opacity', '1');
			
			// 2. Find what the cursor is over - skipping the drag clone and the panel
			// itself, which sit under the pointer and would otherwise answer
			var dropX = p.clientX;
			var dropY = p.clientY;
			var stack = document.elementsFromPoint(dropX, dropY) || [];
			var elementLandedOn = null;
			for (var si = 0; si < stack.length; si++) {
				var cand = stack[si];
				if (cand === document.body || cand === document.documentElement) { continue; }
				if ($(cand).closest('.assistant_view, .ui-draggable-dragging').length) { continue; }
				elementLandedOn = cand;
				break;
			}
			if (!elementLandedOn) { elementLandedOn = stack[stack.length - 1] || document.body; }
			var $target = $(elementLandedOn);
			// a picture is something to look at; an icon is a piece of the program,
			// and both are <img> elements, so ask the markers rather than the tag
			var picture = !assistantImageIsControl(elementLandedOn);
			var base64Data;
			// Set a maximum bound for width or height (Qwen handles 400px - 600px beautifully)
			var maxDimension = 600; 
			var image;
			var audio;
			if ($target.is('img') && picture) {
				var imgElement = $target[0]; // Get raw DOM element
				
				var origWidth = imgElement.naturalWidth || imgElement.width;
				var origHeight = imgElement.naturalHeight || imgElement.height;
				
				// Calculate new scaled dimensions
				var scale = Math.min(maxDimension / origWidth, maxDimension / origHeight, 1);
				var newWidth = origWidth * scale;
				var newHeight = origHeight * scale;

				var canvas = document.createElement('canvas');
				canvas.width = newWidth;
				canvas.height = newHeight;
				
				var ctx = canvas.getContext('2d');
				ctx.drawImage(imgElement, 0, 0, newWidth, newHeight);
				image = canvas.toDataURL('image/png');
				base64Data = image.split(',')[1];

			} else if ($target.is('canvas')) {
				var canvasElement = $target[0];
				
				var origWidth = canvasElement.width;
				var origHeight = canvasElement.height;
				
				var scale = Math.min(maxDimension / origWidth, maxDimension / origHeight, 1);
				var newWidth = origWidth * scale;
				var newHeight = origHeight * scale;

				// Create a temporary downsized canvas
				var tempCanvas = document.createElement('canvas');
				tempCanvas.width = newWidth;
				tempCanvas.height = newHeight;
				
				var ctx = tempCanvas.getContext('2d');
				ctx.drawImage(canvasElement, 0, 0, newWidth, newHeight);
				image = tempCanvas.toDataURL('image/png');
				base64Data = image.split(',')[1];

			} else if ($target.is('video')) {
				var videoElement = $target[0];
				
				var origWidth = videoElement.videoWidth || videoElement.width || 600;
				var origHeight = videoElement.videoHeight || videoElement.height || 400;
				
				var scale = Math.min(maxDimension / origWidth, maxDimension / origHeight, 1);
				var newWidth = origWidth * scale;
				var newHeight = origHeight * scale;
				
				var canvas = document.createElement('canvas');
				canvas.width = newWidth;
				canvas.height = newHeight;
				
				var ctx = canvas.getContext('2d');
				ctx.drawImage(videoElement, 0, 0, newWidth, newHeight);
				image = canvas.toDataURL('image/png');
				base64Data = image.split(',')[1];
			} else if ($target.is('audio')) {
				audio = $target.attr('src');
			}
			
			if (image || audio) {
				assistantDrop(assistantPanel(this), { image: image, base64: base64Data, audio: audio });
			}
			else {
				// a control, a window, or an icon drawn as a picture: the person
				// wants help with the program, not a description of its artwork
				assistantHelpFor(assistantPanel(this), elementLandedOn);
			}

		}
	});
	});
}

// The taskbar rebuilds its pins whenever the order changes, so re-arm the
// assistant's drag each time it lays them out (a pinned assistant is a
// .taskbar_pin with sel="#start_menu #assistant").
$(function () {
	if (typeof jawnosTaskbarOrderApply == 'function') {
		var base = jawnosTaskbarOrderApply;
		jawnosTaskbarOrderApply = function () {
			var r = base.apply(this, arguments);
			assistantIconInitializer();
			return r;
		};
	}
});

$(document).on('click dblclick mouseenter mouseleave keydown keyup change submit focus blur input', function(e) {
	nfcListener();
});

