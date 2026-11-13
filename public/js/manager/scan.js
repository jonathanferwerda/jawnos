// The Scan app: paper that came off the scanner and has not been filed yet.
// A page waits here for a week, the way a capture waits in the Camera app; the
// pool is the same shape, so filing reuses /manager/unclaimed/claim with
// holder=scan. Two buttons take a page, and the kind on each card is read off
// the page's own text - a label, never a destination.
var jawnScan = { items: [], selected: {}, target: null, poll: null };

function scanOpener() {
	$.ajax({
		url: '/manager/scan',
		type: 'GET',
		data: { timestamp: Date.now(), user_agent: navigator.userAgent },
		success: function (response) { windowMaker(response); jawnScanPool(); }
	});
}

$(document).on('click', '#scan_toggle', scanOpener);

// The notice names the Scan app, so pressing it brings the pool forward.
$(document).on('click', '.notification[app="scan"]', function (e) {
	if ($(e.target).hasClass('notification_remove')) { return; }
	scanOpener();
});

function jawnScanStatus(text) {
	$('#scan_app .scan_app_status').text(text || '');
}

function jawnScanPool() {
	if (!$('#scan_app').length) { return; }
	$.ajax({
		url: '/manager/scan/pool',
		type: 'GET',
		data: { timestamp: Date.now() },
		success: function (res) {
			jawnScan.items = (res && res.items) || [];
			jawnScan.selected = {};
			jawnScan.target = null;
			var where = $('#scan_app .scan_where');
			if (res && res.scanner) {
				where.text(res.here ? jawnosT('This machine scans.') : jawnosT('Scans run on') + ' ' + res.scanner + '.');
			}
			else { where.text(''); }
			jawnScanRender();
		},
		error: function () { jawnScanStatus(jawnosT('Could not load the scans.')); }
	});
}

function jawnScanLeft(ms) {
	var left = Number(ms || 0) - Date.now();
	if (left <= 0) { return jawnosT('expired'); }
	var m = Math.floor(left / 60000);
	var h = Math.floor(m / 60);
	var d = Math.floor(h / 24);
	if (d > 0) { return d + 'd ' + (h % 24) + 'h'; }
	if (h > 0) { return h + 'h ' + (m % 60) + 'm'; }
	return m + 'm';
}

function jawnScanSrc(item, thumb) {
	return '/file_open?appt_uuid=' + encodeURIComponent(item.appt_uuid) +
		'&file_uuid=' + encodeURIComponent(item.file_uuid) +
		'&app=scan&timestamp=' + encodeURIComponent(item.server_time || '') +
		(thumb ? '&thumb=ya' : '');
}

function jawnScanMedia(item) {
	if (item.file_type === 'img') {
		return $('<img class="scan_thumb" loading="lazy">').attr('src', jawnScanSrc(item, true));
	}
	if (item.file_type === 'pdf') {
		return $('<img class="scan_thumb scan_icon">').attr('src', '/images/decipherable/file.png');
	}
	return $('<img class="scan_thumb scan_icon">').attr('src', '/images/decipherable/file.png');
}

function jawnScanRender() {
	var pool = $('#scan_app .scan_pool').empty();
	$('#scan_app .scan_pool_count').text(jawnScan.items.length ? '(' + jawnScan.items.length + ')' : '');
	$('#scan_app .scan_select_all_wrap').toggle(jawnScan.items.length > 0);
	$('#scan_app .scan_select_all').prop('checked', false);
	if (!jawnScan.items.length) {
		$('#scan_app .scan_claim').hide();
		jawnScanStatus(jawnosT('Nothing is waiting here yet.'));
		return;
	}
	jawnScanStatus('');

	$.each(jawnScan.items, function (i, item) {
		var card = $('<div class="scan_item"></div>')
			.attr('file_uuid', item.file_uuid)
			.attr('appt_uuid', item.appt_uuid)
			.attr('title', item.text || item.name || '');
		var check = $('<input type="checkbox" class="scan_check">');
		var meta = $('<div class="scan_meta">' +
			'<span class="scan_kind">' + (item.kind || 'document') + '</span>' +
			'<span class="scan_time">' + jawnScanLeft(item.warranty) + '</span>' +
			'</div>');
		var drop = $('<button class="scan_drop" title="' + jawnosT('Discard') + '">&times;</button>');
		drop.on('click', function (e) {
			e.stopPropagation();
			jawnScanDiscard(item);
		});
		card.append(check).append(jawnScanMedia(item)).append(meta).append(drop);
		card.on('click', function () {
			check.prop('checked', !check.prop('checked')).trigger('change');
		});
		check.on('change', function () {
			if (check.prop('checked')) { jawnScan.selected[item.file_uuid] = 1; }
			else { delete jawnScan.selected[item.file_uuid]; }
			card.toggleClass('selected', check.prop('checked'));
			jawnScanClaimState();
		});
		pool.append(card);
	});
	jawnScanClaimState();
}

function jawnScanSelectedIds() {
	return $.map(jawnScan.selected, function (v, k) { return k; });
}

function jawnScanClaimState() {
	var ids = jawnScanSelectedIds();
	$('#scan_app .scan_claim').toggle(ids.length > 0);
	$('#scan_app .scan_claim_target').text(
		jawnScan.target ? (ids.length + ' ' + jawnosT('page(s)') + ' \u2192 ' + jawnScan.target.name) : '');
	$('#scan_app .scan_claim_file').toggle(!!jawnScan.target && ids.length > 0);
}

function jawnScanSearch() {
	var input = $('#scan_app .scan_claim_search');
	var results = $('#scan_app .scan_claim_results');
	var q = $.trim(input.val());
	if (!q) { results.empty().hide(); return; }
	$.ajax({
		url: '/manager/unclaimed/appointments',
		type: 'GET',
		data: { search: q, timestamp: Date.now() },
		success: function (res) {
			var list = (res && res.appointments) || [];
			results.empty();
			if (!list.length) {
				results.append($('<div class="scan_claim_result" style="opacity:.6;"></div>').text(jawnosT('No appointments match.')));
			}
			$.each(list, function (i, a) {
				var row = $('<div class="scan_claim_result"></div>').text(a.name);
				row.on('click', function () {
					jawnScan.target = { app: a.app, uuid: a.uuid || '', name: a.name };
					results.hide();
					input.val(a.name);
					jawnScanClaimState();
				});
				results.append(row);
			});
			results.show();
		}
	});
}

function jawnScanFile() {
	var ids = jawnScanSelectedIds();
	var target = jawnScan.target;
	if (!ids.length || !target) { return; }
	jawnScanStatus(jawnosT('Filing…'));
	$.ajax({
		url: '/manager/unclaimed/claim',
		type: 'POST',
		data: { app: target.app, uuid: target.uuid || '', file_uuids: ids.join(','), holder: 'scan', timestamp: Date.now() },
		success: function (res) {
			if (res && res.ok) {
				jawnScanStatus(jawnosT('Filed') + ' ' + res.claimed + ' ' + jawnosT('page(s)') + ' \u2192 ' + target.name);
				jawnScanPool();
			}
			else { jawnScanStatus((res && res.error) || jawnosT('Could not file those pages.')); }
		},
		error: function () { jawnScanStatus(jawnosT('Could not file those pages.')); }
	});
}

function jawnScanDiscard(item) {
	jawnosConfirm(jawnosT('Throw this scan away?'), function () { jawnScanDiscardNow(item); });
}

function jawnScanDiscardNow(item) {
	$.ajax({
		url: '/manager/scan/discard',
		type: 'POST',
		data: { appt_uuid: item.appt_uuid, file_uuid: item.file_uuid, timestamp: Date.now() },
		success: function (res) {
			if (res && res.ok) { jawnScanPool(); }
			else { jawnScanStatus((res && res.error) || jawnosT('Could not discard that scan.')); }
		},
		error: function () { jawnScanStatus(jawnosT('Could not discard that scan.')); }
	});
}

function jawnScanWatch() {
	clearInterval(jawnScan.poll);
	var tries = 0;
	jawnScan.poll = setInterval(function () {
		tries++;
		jawnScanPool();
		if (tries > 60) { clearInterval(jawnScan.poll); }
	}, 2000);
}

$(document).on('click', '#scan_app .scan_feed', function () {
	var feed = $(this).attr('feed');
	jawnScanStatus(jawnosT('Scanning…'));
	$.ajax({
		url: '/manager/scan/capture',
		type: 'POST',
		data: { feed: feed, timestamp: Date.now() },
		success: function (res) {
			if (res && res.ok) {
				jawnScanStatus(jawnosT('Scanning - the page will appear here.'));
				jawnScanWatch();
			}
			else { jawnScanStatus((res && res.error) || jawnosT('The scan could not be started.')); }
		},
		error: function () { jawnScanStatus(jawnosT('The scan could not be started.')); }
	});
});

$(document).on('input', '#scan_app .scan_claim_search', function () {
	clearTimeout(jawnScan._t);
	jawnScan._t = setTimeout(jawnScanSearch, 180);
});

$(document).on('click', '#scan_app .scan_claim_file', jawnScanFile);

$(document).on('change', '#scan_app .scan_select_all', function () {
	var on = $(this).prop('checked');
	$('#scan_app .scan_item .scan_check').each(function () {
		if ($(this).prop('checked') !== on) { $(this).prop('checked', on).trigger('change'); }
	});
});
