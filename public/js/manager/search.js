// Search is one window with three contexts: Apps (the house's appointments and
// apps), Web (the domains in config.json's search_engines), and AI (the Guide's
// model). Only the active tab is asked, and the tab is remembered, so a search
// never mixes the three. A web result opens the JawnOS Browser - the Search
// window itself stays where it is.
( function () {
	if (window.jawnosSearchAppOpen) { return; }

	function T(text) { return (typeof jawnosT === 'function') ? jawnosT(text) : text; }

	var TAB_KEY = 'jawnos_search_tab';
	var state = { tab: 'apps', seq: 0, timer: null, lastAI: '' };

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
		if (!any) { note(T('No web results.')); return; }
		results().empty().append(box);
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
