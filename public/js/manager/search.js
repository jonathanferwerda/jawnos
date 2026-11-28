// Search is one window with three contexts: Apps (the house's appointments and
// apps), Web (the engines that are switched on), and AI (a conversation with the
// model chosen in its own row). Only the active tab is asked, and the tab is
// remembered, so a search never mixes the three. A web result opens the JawnOS
// Browser - the Search window itself stays where it is. The gear on the tabs row
// opens the engine settings (searchable, enabled engines first) and a Browser
// button can add a site.
( function () {
	if (window.jawnosSearchAppOpen) { return; }

	function T(text) { return (typeof jawnosT === 'function') ? jawnosT(text) : text; }

	var TAB_KEY = 'jawnos_search_tab';
	var AI_MODEL_KEY = 'jawnos_search_ai_model';
	var state = { tab: 'apps', seq: 0, timer: null, engines: null, enginesFilter: '', messages: [] };

	function storedTab() {
		var tab = '';
		try { tab = localStorage.getItem(TAB_KEY) || ''; } catch (e) { tab = ''; }
		return (tab === 'web' || tab === 'ai') ? tab : 'apps';
	}

	function saveTab(tab) {
		state.tab = tab;
		try { localStorage.setItem(TAB_KEY, tab); } catch (e) {}
	}

	function results() { return $('#search_app_results'); }

	function note(text) {
		results().empty().append($('<div class="search_app_note"></div>').text(text));
	}

	function busy(text) {
		results().empty().append($('<div class="search_app_note"></div>').text(text));
	}

	function markTabs() {
		$('#search_app .search_app_tab').removeClass('selected')
			.filter('[data-tab="' + state.tab + '"]').addClass('selected');
		$('#search_app').toggleClass('ai_mode', state.tab === 'ai');
		layout();
	}

	// An AI thread takes the window over: the question field moves from the top
	// to the bottom composer while there are turns, and back when the thread is
	// empty or another tab is chosen. One field, moved, so every saver and the
	// Enter handler keep working.
	function conversing() {
		return state.tab === 'ai' && state.messages.length > 0;
	}

	function layout() {
		var root = $('#search_app');
		if (!root.length) { return; }
		var chat = conversing();
		root.toggleClass('ai_conversation', chat);
		var input = $('#search_app_input');
		var home = chat ? $('#search_app_ai_composer') : $('#search_app_bar');
		if (input.length && home.length && input[0].parentNode !== home[0]) {
			var hadFocus = document.activeElement === input[0];
			if (chat) { home.prepend(input); } else { home.append(input); }
			if (hadFocus) { input.focus(); }
		}
		if (input.length) {
			input.attr('placeholder', state.tab === 'ai'
				? (input.attr('data-ai-placeholder') || input.attr('data-search-placeholder') || '')
				: (input.attr('data-search-placeholder') || ''));
		}
		$('#search_app_ai_clear, #search_app_ai_pen').prop('disabled', !state.messages.length);
	}

	function query() {
		return $.trim($('#search_app_input').val() || '');
	}

	// The model the AI tab talks to is remembered in this browser. A stored value
	// the catalogue no longer offers is ignored, so a removed provider falls back
	// to the server's default rather than sending a dead id.
	function aiModelRestore() {
		var sel = $('#search_app_ai_model');
		if (!sel.length) { return; }
		var stored = null;
		try { stored = localStorage.getItem(AI_MODEL_KEY); } catch (e) { stored = null; }
		if (stored === null) { return; }
		var exists = sel.find('option').filter(function () { return this.value === stored; });
		if (exists.length) { sel.val(stored); }
	}

	// The AI tab is a conversation: the whole thread is redrawn from state after
	// every turn, so a re-render cannot lose it.
	function renderThread() {
		var box = results().empty();
		if (!state.messages.length) { note(T('Ask a question and press Enter.')); layout(); return; }
		var thread = $('<div class="search_app_thread"></div>');
		$.each(state.messages, function (i, m) {
			thread.append($('<div class="search_app_msg"></div>')
				.addClass(m.role === 'user' ? 'search_app_msg_user' : 'search_app_msg_ai')
				.append($('<div class="search_app_msg_text"></div>').text(m.content)));
		});
		box.append(thread);
		layout();
	}

	function aiSay(role, text) {
		state.messages.push({ role: role, content: text });
		renderThread();
		var box = results();
		if (box.length) { box.scrollTop(box[0].scrollHeight); }
	}

	function renderApps(list) {
		if (!list.length) { note(T('No apps match.')); return; }
		var box = $('<div>');
		$.each(list, function (i, entry) {
			var row = $('<div class="search_app_row search_app_app"></div>').attr('app', entry.app);
			if (entry.icon) {
				row.append($('<img class="search_app_icon" alt="">').attr('src', entry.icon));
			}
			row.append($('<div class="search_app_text"></div>')
				.append($('<div class="search_app_title"></div>').text(entry.name || entry.app)));
			box.append(row);
		});
		results().empty().append(box);
	}

	function renderWeb(engines) {
		var box = $('<div>');
		var any = false;
		$.each(engines || [], function (i, engine) {
			box.append($('<div class="search_app_engine"></div>')
				.text(engine.name + (engine.error ? ' - ' + engine.error : '')));
			$.each(engine.results || [], function (j, item) {
				any = true;
				var row = $('<div class="search_app_row search_app_web"></div>').attr('href', item.url);
				var text = $('<div class="search_app_text"></div>')
					.append($('<div class="search_app_title"></div>').text(item.title || item.url))
					.append($('<div class="search_app_url"></div>').text(item.url));
				if (item.snippet) {
					text.append($('<div class="search_app_snippet"></div>').text(item.snippet));
				}
				row.append(text);
				box.append(row);
			});
		});
		if (!any) { noEngines(); return; }
		results().empty().append(box);
	}

	function noEngines() {
		var root = results().empty();
		root.append($('<div class="search_app_note"></div>')
			.append($('<span></span>').text(T('No search engines are on.')))
			.append($('<button type="button" class="search_app_open_settings"></button>')
				.text(T('Choose search engines'))));
	}

	function engineEnabled() {
		if (!state.engines) { return true; }
		return state.engines.some(function (e) { return !!e.enabled; });
	}

	function loadEngines(draw) {
		$.getJSON('/manager/search/engines', function (data) {
			state.engines = (data && data.engines) || [];
			if (draw !== false) { renderEngines(); }
		}).fail(function () {
			if (draw !== false) { $('#search_app_engine_list').empty().append($('<div class="search_app_note"></div>').text(T('The engines did not load.'))); }
		});
	}

	function renderEngines() {
		var list = (state.engines || []).slice();
		var filter = $.trim(state.enginesFilter || '').toLowerCase();
		list.sort(function (a, b) {
			if (!!a.enabled !== !!b.enabled) { return a.enabled ? -1 : 1; }
			return String(a.name || a.id).localeCompare(String(b.name || b.id));
		});
		var box = $('#search_app_engine_list').empty();
		var shown = 0;
		$.each(list, function (i, engine) {
			var hay = (engine.name + ' ' + engine.id + ' ' + (engine.group || '') + ' ' + (engine.group_label || '')).toLowerCase();
			if (filter && hay.indexOf(filter) < 0) { return; }
			shown++;
			var row = $('<div class="search_app_engine_row"></div>').toggleClass('on', !!engine.enabled);
			row.append($('<input type="checkbox" class="search_app_engine_toggle">')
				.attr('data-id', engine.id).prop('checked', !!engine.enabled));
			row.append($('<span class="search_app_engine_name"></span>').text(engine.name || engine.id));
			if (engine.custom) {
				row.append($('<span class="search_app_engine_remove" title="' + T('Remove') + '"></span>')
					.attr('data-id', engine.id).text('\u00d7'));
			}
			else {
				row.append($('<span class="search_app_engine_group"></span>').text(engine.group_label || engine.group || ''));
			}
			box.append(row);
		});
		if (!shown) {
			box.append($('<div class="search_app_note"></div>').text(T('No engine matches that.')));
		}
	}

	function settingsOpen(open) {
		var root = $('#search_app');
		var next = (open === undefined) ? !root.hasClass('settings_open') : !!open;
		root.toggleClass('settings_open', next);
		if (next) { loadEngines(true); }
	}

	function run() {
		var q = query();
		var tab = state.tab;
		var seq = ++state.seq;
		clearTimeout(state.timer);
		markTabs();

		if (!q.length) {
			if (tab === 'apps') { note(T('Type a name to find an app.')); }
			else if (tab === 'web') { note(T('Type a search and press Enter.')); }
			else { renderThread(); }
			return;
		}

		if (tab === 'apps') {
			busy(T('Searching...'));
			$.getJSON('/manager/search/apps', { search: q }, function (data) {
				if (seq !== state.seq) { return; }
				renderApps((data && data.apps) || []);
			}).fail(function () {
				if (seq === state.seq) { note(T('The house did not answer.')); }
			});
			return;
		}

		if (tab === 'web') {
			if (q.length < 2) { note(T('Type at least two letters.')); return; }
			if (!engineEnabled()) { noEngines(); return; }
			busy(T('Searching the web...'));
			$.getJSON('/manager/search/web', { q: q }, function (data) {
				if (seq !== state.seq) { return; }
				renderWeb((data && data.engines) || []);
			}).fail(function () {
				if (seq === state.seq) { note(T('The house did not answer.')); }
			});
			return;
		}

		// AI: one question per Enter, with the earlier turns as context. The
		// chosen model rides with the call; the window keeps the thread.
		var model = $('#search_app_ai_model').val() || '';
		var prior = state.messages.slice(-20);
		aiSay('user', q);
		$('#search_app_input').val('');
		var pending = $('<div class="search_app_msg search_app_msg_ai search_app_thinking"></div>').text(T('Thinking...'));
		results().find('.search_app_thread').append(pending);
		var box = results();
		if (box.length) { box.scrollTop(box[0].scrollHeight); }
		$.post('/manager/search/ai', { q: q, model: model, messages: JSON.stringify(prior) }, function (data) {
			if (seq !== state.seq) { return; }
			pending.remove();
			if (!data || !data.ok || !data.answer) {
				aiSay('assistant', (data && data.error) || T('The AI did not answer.'));
				return;
			}
			aiSay('assistant', data.answer);
		}).fail(function () {
			if (seq === state.seq) { pending.remove(); aiSay('assistant', T('The AI did not answer.')); }
		});
	}

	function initialise() {
		var root = $('#search_app');
		if (!root.length) { return; }
		var tab = storedTab();
		if (root.attr('data-ready') !== 'yes') {
			root.attr('data-ready', 'yes');
			saveTab(tab);
		}
		markTabs();
		// An empty query draws the tab's own hint; a query handed over by the
		// dock's magnifier is searched at once. The magnifier also sets the Apps
		// tab, so the query lands on the house's own records.
		aiModelRestore();
		loadEngines(false);
		run();
	}

	// `tab` lets the caller pick the context. The dock's magnifier passes 'apps'
	// because typing in #search is a house search; no tab keeps the context the
	// window last remembered (the start menu's Search icon).
	window.jawnosSearchAppOpen = function (search, tab) {
		var q = (search == null) ? '' : String(search);
		if (tab === 'apps' || tab === 'web' || tab === 'ai') { saveTab(tab); }
		$('#search_results').hide();
		$('#start_menu').hide();
		if (typeof pseudonymHomeHider === 'function') { pseudonymHomeHider(pseudonymHIntervals); }
		$.ajax({
			url: '/manager/search',
			type: 'GET',
			data: { q: q, timestamp: Date.now() },
			success: function (response) {
				if (typeof windowMaker === 'function') { windowMaker(response); }
				setTimeout(initialise, 40);
			}
		});
	};

	$(document).on('click', '#search_app_tabs .search_app_tab', function () {
		var tab = $(this).attr('data-tab') || 'apps';
		saveTab(tab);
		run();
	});

	$(document).on('click', '#search_app_gear', function (e) {
		e.preventDefault();
		settingsOpen();
	});

	$(document).on('click', '#search_app_engines_refresh', function (e) {
		e.preventDefault();
		loadEngines(true);
	});

	$(document).on('input', '#search_app_engine_filter', function () {
		state.enginesFilter = $(this).val() || '';
		renderEngines();
	});

	$(document).on('change', '.search_app_engine_toggle', function () {
		var id = $(this).attr('data-id');
		var on = $(this).is(':checked') ? 1 : 0;
		$.each(state.engines || [], function (i, engine) {
			if (engine.id === id) { engine.enabled = on; }
		});
		renderEngines();
		$.post('/manager/search/engines/toggle', { id: id, enabled: on }, function () {
			if (state.tab === 'web') { run(); }
		}).fail(function () { loadEngines(true); });
	});

	$(document).on('click', '.search_app_engine_remove', function (e) {
		e.preventDefault();
		e.stopPropagation();
		var id = $(this).attr('data-id');
		$.post('/manager/search/engines/remove', { id: id }, function () { loadEngines(true); });
	});

	$(document).on('click', '.search_app_open_settings', function (e) {
		e.preventDefault();
		settingsOpen(true);
	});

	$(document).on('input', '#search_app_input', function () {
		clearTimeout(state.timer);
		if (state.tab === 'ai') {
			// the AI is asked on Enter, not on every letter, and typing must not
			// wipe the conversation under it
			return;
		}
		state.timer = setTimeout(run, 350);
	});

	$(document).on('keydown', '#search_app_input', function (e) {
		if (e.keyCode == 13) {
			e.preventDefault();
			clearTimeout(state.timer);
			run();
		}
	});

	$(document).on('click', '.search_app_app', function () {
		var app = $(this).attr('app');
		if (app && typeof jawnosSearchOpen === 'function') { jawnosSearchOpen(app); }
	});

	$(document).on('click', '.search_app_web', function (e) {
		e.preventDefault();
		var url = $(this).attr('href');
		if (!url) { return; }
		if (typeof internetLaunch === 'function') { internetLaunch(url, 'browse', '', ''); }
		else { window.open(url, '_blank'); }
	});

	$(document).on('change', '#search_app_ai_model', function () {
		try { localStorage.setItem(AI_MODEL_KEY, $(this).val() || ''); } catch (e) {}
	});

	function clearThread() {
		state.messages = [];
		renderThread();
		$('#search_app_input').val('').focus();
	}

	$(document).on('click', '#search_app_ai_new, #search_app_ai_clear', function (e) {
		e.preventDefault();
		clearThread();
	});

	// Copy the thread into the Pen as a conversation of its own, then open the
	// Pen on it. The Search copy is cleared because the words now live there.
	$(document).on('click', '#search_app_ai_pen', function (e) {
		e.preventDefault();
		if (!state.messages.length) { return; }
		var button = $(this);
		button.prop('disabled', true);
		var model = $('#search_app_ai_model').val() || '';
		$.post('/manager/search/ai/pen', { messages: JSON.stringify(state.messages), model: model }, function (data) {
			if (!data || !data.ok) {
				button.prop('disabled', false);
				note((data && data.error) || T('The Pen could not take the conversation.'));
				return;
			}
			state.messages = [];
			renderThread();
			$('#search_app_input').val('');
			if (typeof mailMaker === 'function') { mailMaker(null, 'pen'); }
			else if (typeof jawnosSearchOpen === 'function') { jawnosSearchOpen('pen'); }
		}).fail(function () {
			button.prop('disabled', false);
			note(T('The Pen could not take the conversation.'));
		});
	});

	$(document).on('click', '#search_app_toggle', function (e) {
		e.preventDefault();
		window.jawnosSearchAppOpen($('#search').val() || '');
	});

	// A window restored by the window manager draws the saved tab and query.
	$(document).on('focusin click', '#search_app', function () {
		if ($('#search_app').attr('data-ready') !== 'yes') { initialise(); }
	});
} )();
