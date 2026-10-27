// Internet gathers the two ways the house reaches the web: Web, the pages the
// server fetched and can measure, and Browse, a real browser that runs as a
// native window (desktop) or activity (Android) because a live page cannot be
// nested inside the manager's own WebView. Browse reports what it saw here, so
// site-time and a page measure both start in this window.
( function () {
	if (window.internetTab) { return; }

	window.internetTab = function (name) {
		name = (name === 'browse') ? 'browse' : 'web';
		try { localStorage.setItem('internet_tab', name); } catch (e) {}
		$('.internet_tab').removeClass('selected');
		$('.internet_tab[data-internet-tab="' + name + '"]').addClass('selected');
		$('.internet_pane').hide();
		$('#internet_' + name).show();
		if (name === 'browse') { window.internetLoadSites(); }
	};

	window.internetDuration = function (ms) {
		ms = parseInt(ms, 10) || 0;
		var s = Math.round(ms / 1000);
		if (s < 60) { return s + 's'; }
		var m = Math.floor(s / 60);
		if (m < 60) { return m + 'm'; }
		var h = Math.floor(m / 60);
		return h + 'h ' + ('0' + (m % 60)).slice(-2) + 'm';
	};

	window.internetAppTitle = function (apps, app) {
		for (var i = 0; i < (apps || []).length; i++) {
			if (apps[i].app === app) { return apps[i].title || app; }
		}
		return app;
	};

	// The native browser is the only surface that can count a site and pick an
	// element. A plain browser still opens the page, but nothing is timed there.
	window.internetLaunch = function (url, mode, app, uuid) {
		url = url || '';
		mode = mode || 'browse';
		app = app || '';
		uuid = uuid || '';
		if (window.JawnBrowse && typeof window.JawnBrowse.open === 'function') {
			window.JawnBrowse.open(url, mode, app, uuid);
			return true;
		}
		if (mode === 'measure') {
			alert('Measuring a live page needs the installed JawnOS app.');
			return false;
		}
		if (url) { window.open(url, '_blank'); }
		return false;
	};

	window.internetGo = function () {
		var url = ($('#internet_url').val() || '').trim();
		if (!url) { return; }
		if (!/^[a-z]+:\/\//i.test(url)) { url = 'https://' + url; }
		window.internetLaunch(url, 'browse', '', '');
	};

	window.internetOpenSaved = function (el, mode) {
		var row = $(el).closest('.internet_saved');
		window.internetLaunch(row.attr('data-url'), mode, row.attr('data-app'), row.attr('data-uuid'));
	};

	window.internetOpenWeb = function () {
		$.ajax({
			url: '/manager/web',
			type: 'GET',
			data: { timestamp: Date.now() },
			success: function (response) { if (typeof windowMaker === 'function') { windowMaker(response); } }
		});
	};

	// Domains the browser counted (and the saved pages as bookmarks), each with
	// the app it belongs to. The domain opens the browser; the app opens its
	// appointment. A select beside each row assigns or clears the mapping.
	window.internetLoadSites = function () {
		$.getJSON('/manager/internet/sites', function (data) {
			var apps = (data && data.apps) || [];
			var sites = (data && data.sites) || [];
			window.internetApps = apps;
			var body = $('#internet_sites tbody').empty();
			$('#internet_usage_none').toggle(sites.length === 0);
			$.each(sites, function (i, site) {
				var row = $('<tr>');
				row.append($('<td>').append(
					$('<a href="#">').addClass('internet_site_open').attr('data-url', site.url || ('https://' + site.domain + '/')).text(site.domain)
				));
				var appCell = $('<td>');
				if (site.app) {
					appCell.append($('<a href="#">').addClass('internet_site_app').attr('data-app', site.app)
						.text(window.internetAppTitle(apps, site.app)));
					appCell.append(' ');
				}
				// Type to find the app this site belongs to. The old select listed
				// every app the house knew in one long menu; the box filters the
				// same catalogue as you type, and a dash clears the mapping.
				var picker = $('<span class="internet_site_picker"></span>');
				picker.append($('<input type="text" autocomplete="off">')
					.addClass('internet_site_app_input themed_input')
					.attr('data-domain', site.domain)
					.attr('placeholder', window.internetAppTitle(apps, site.app) || 'App'));
				picker.append($('<div class="internet_app_results"></div>'));
				appCell.append(picker);
				row.append(appCell);
				row.append($('<td>').text(window.internetDuration(site.total_ms)));
				row.append($('<td>'));
				row.appendTo(body);
			});
		});
	};

	$(document).on('click', '.internet_site_open, .internet_open_url', function (e) {
		e.preventDefault();
		window.internetLaunch($(this).attr('data-url'), 'browse', '', '');
	});

	$(document).on('click', '.internet_site_app, .internet_open_app', function (e) {
		e.preventDefault();
		var app = $(this).attr('data-app');
		if (app && typeof appointmentGrabber === 'function') { appointmentGrabber(app); }
	});

	$(document).on('input', '.internet_site_app_input', function () {
		var input = $(this);
		var box = input.siblings('.internet_app_results');
		var q = $.trim(input.val() || '').toLowerCase().replace(/_/g, ' ');
		var apps = window.internetApps || [];
		var shown = 0;
		box.empty();
		// a dash is the way to clear the mapping; picking an app replaces it
		box.append($('<div class="internet_app_result internet_app_clear">')
			.attr('data-app', '').text('-'));
		$.each(apps, function (i, entry) {
			if (shown >= 12) { return false; }
			var hay = (entry.app + ' ' + (entry.title || '')).toLowerCase().replace(/_/g, ' ');
			if (q && hay.indexOf(q) < 0) { return; }
			box.append($('<div class="internet_app_result">').attr('data-app', entry.app)
				.text(entry.title || entry.app));
			shown++;
		});
		box.show();
	});

	// mousedown, not click: the input's blur happens first on a phone and would
	// take the list away before the press landed
	$(document).on('mousedown', '.internet_app_result', function (e) {
		e.preventDefault();
		var row = $(this).closest('tr');
		var input = row.find('.internet_site_app_input');
		var domain = input.attr('data-domain') || '';
		var app = $(this).attr('data-app') || '';
		row.find('.internet_app_results').hide();
		$.post('/manager/internet/site/app', { domain: domain, app: app }, function () {
			window.internetLoadSites();
		});
	});

	$(document).on('keydown', '.internet_site_app_input', function (e) {
		var box = $(this).siblings('.internet_app_results');
		if (e.keyCode == 27) { box.hide(); return; }
		if (e.keyCode != 13) { return; }
		e.preventDefault();
		box.find('.internet_app_result').first().trigger('mousedown');
	});

	$(document).on('focusout', '.internet_site_app_input', function () {
		var box = $(this).siblings('.internet_app_results');
		setTimeout(function () { box.hide(); }, 150);
	});

	$(document).on('click', '#internet_toggle', function () {
		$.ajax({
			url: '/manager/internet',
			type: 'GET',
			data: { timestamp: Date.now(), user_agent: navigator.userAgent },
			success: function (response) {
				if (typeof windowMaker === 'function') { windowMaker(response); }
				setTimeout(function () {
					var tab = 'web';
					try { tab = localStorage.getItem('internet_tab') || 'web'; } catch (e) { tab = 'web'; }
					window.internetTab(tab);
				}, 50);
			}
		});
	});
} )();
