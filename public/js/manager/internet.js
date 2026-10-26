// Internet gathers the two ways the house reaches the web: Web, the pages the
// server fetched and can measure, and Browse, a real browser that runs as a
// native window (desktop) or activity (Android) because a live page cannot be
// nested inside the manager's own WebView. Browse reports what it saw here, so
// site-time and a page measure both start in this window.
( function () {
	if (window.internetTab) { return; }

	window.internetTab = function (name) {
		$('.internet_tab').removeClass('selected');
		$('.internet_tab[data-internet-tab="' + name + '"]').addClass('selected');
		$('.internet_pane').hide();
		$('#internet_' + name).show();
		if (name === 'browse') { window.internetLoadUsage(); }
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

	window.internetLoadUsage = function () {
		var day = new Date();
		day.setHours(0, 0, 0, 0);
		$.getJSON('/manager/usage/summary', { kind: 'site', from: day.getTime(), to: Date.now() }, function (data) {
			var rows = (data && data.rows) || [];
			var body = $('#internet_usage tbody').empty();
			$('#internet_usage_none').toggle(rows.length === 0);
			$.each(rows, function (i, row) {
				$('<tr>')
					.append($('<td>').text(row.key || row.key_name || ''))
					.append($('<td>').text(window.internetDuration(row.total_ms)))
					.appendTo(body);
			});
		});
	};

	$(document).on('click', '#internet_toggle', function () {
		$.ajax({
			url: '/manager/internet',
			type: 'GET',
			data: { timestamp: Date.now(), user_agent: navigator.userAgent },
			success: function (response) { if (typeof windowMaker === 'function') { windowMaker(response); } }
		});
	});
} )();
