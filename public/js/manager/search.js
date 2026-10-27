// Search is one window with three contexts: Apps (the house's appointments and
// apps), Web (the engines that are switched on), and AI (the Guide's model).
// Only the active tab is asked, and the tab is remembered, so a search never
// mixes the three. A web result opens the JawnOS Browser - the Search window
// itself stays where it is. The gear on the tabs row opens the engine settings
// (searchable, enabled engines first) and a Browser button can add a site.
( function () {
	if (window.jawnosSearchAppOpen) { return; }

	function T(text) { return (typeof jawnosT === 'function') ? jawnosT(text) : text; }

	var TAB_KEY = 'jawnos_search_tab';
	var state = { tab: 'apps', seq: 0, timer: null, lastAI: '', engines: null, enginesFilter: '' };

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
	}

	function query() {
		return $.trim($('#search_app_input').val() || '');
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
			else { note(T('Ask a question and press Enter.')); }
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

		// AI: one question per Enter/open, never once per keystroke.
		if (state.lastAI === q && results().find('.search_app_answer').length) { return; }
		state.lastAI = q;
		busy(T('Thinking...'));
		$.post('/manager/search/ai', { q: q }, function (data) {
			if (seq !== state.seq) { return; }
			if (!data || !data.ok || !data.answer) {
				note((data && data.error) || T('The AI did not answer.'));
				return;
			}
			results().empty().append($('<div class="search_app_answer"></div>').text(data.answer));
		}).fail(function () {
			if (seq === state.seq) { note(T('The AI did not answer.')); }
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
		// dock's magnifier is searched at once, whichever tab was last used.
		loadEngines(false);
		run();
	}

	window.jawnosSearchAppOpen = function (search) {
		var q = (search == null) ? '' : String(search);
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
		state.lastAI = '';
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
			// the AI is asked on Enter, not on every letter
			note(T('Press Enter to ask.'));
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

	$(document).on('click', '#search_app_toggle', function (e) {
		e.preventDefault();
		window.jawnosSearchAppOpen($('#search').val() || '');
	});

	// A window restored by the window manager draws the saved tab and query.
	$(document).on('focusin click', '#search_app', function () {
		if ($('#search_app').attr('data-ready') !== 'yes') { initialise(); }
	});
} )();
