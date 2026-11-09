// ---- the records watch's staging area ---------------------------------------
// The mirror of the error watch's fixes: findings the fixed audit staged, each
// with the rows it proposes to tombstone or repair. Nothing is written until
// Apply. The list re-fetches after each action, and scan now runs the audit.
function recordsRender() {
	var list = $('#records_list');
	list.show().html('Loading…');
	$.get('/manager/records/fixes', function(res) {
		var rows = (res && res.findings) || [];
		$('#records_waiting_n').text(rows.length ? (rows.length + ' waiting') : 'nothing waiting');
		if (!rows.length) { list.html('<div style="opacity:.6;">Nothing waiting.</div>'); return; }
		list.html('');
		$.each(rows, function(i, f) {
			var acts = (f.proposed && f.proposed.actions) || [];
			var line = $('<div style="padding:6px 0;border-top:1px solid var(--line);"></div>');
			line.append($('<div></div>').text((f.kind || '') + ' · ' + (f.app || '') + ' — ' + (f.sample || '')));
			line.append($('<div style="opacity:.7;"></div>').text(acts.length + ' action(s): ' + $.map(acts, function(a){ return a.action + ' ' + String(a.uuid || '').slice(0, 10); }).join(', ')));
			var bar = $('<div style="margin-top:4px;display:flex;gap:8px;flex-wrap:wrap;"></div>');
			$('<button type="button"></button>').addClass('records_apply').attr('uuid', f.uuid).text('Apply').appendTo(bar);
			$('<button type="button"></button>').addClass('records_discard').attr('uuid', f.uuid).text('Discard').appendTo(bar);
			$('<button type="button"></button>').addClass('records_leave_app').attr('uuid', f.uuid).attr('app', f.app || '').text('Leave this app alone').appendTo(bar);
			line.append(bar);
			// the findings a rule cannot judge - a genuinely long appointment - can be put
			// to the Coding agent and talked through before anything is applied
			var area = $('<div class="records_ask_area" style="margin-top:6px;"></div>');
			var ans = $('<div class="records_answer" style="white-space:pre-wrap;opacity:.85;"></div>');
			var askrow = $('<div style="display:flex;gap:6px;margin-top:4px;"></div>');
			$('<input type="text" class="records_ask_q" placeholder="Ask the Coding agent about this finding…"></input>').css({ flex: '1', minWidth: '0' }).appendTo(askrow);
			$('<button type="button"></button>').addClass('records_ask').attr('uuid', f.uuid).text('Ask').appendTo(askrow);
			area.append(ans, askrow);
			line.append(area);
			list.append(line);
		});
	}).fail(function() { list.html('<div style="opacity:.6;">Could not load the findings.</div>'); });
}
$(document).on('click', '#records_open', function() {
	if ($('#records_list').is(':visible')) { $('#records_list').hide(); return; }
	recordsRender();
});
$(document).on('click', '.records_apply', function() {
	var b = $(this); b.prop('disabled', true).text('…');
	$.post('/manager/records/fixes_apply', { uuid: b.attr('uuid') }, function() { recordsRender(); $('#records_fixed_list').hide(); });
});
$(document).on('click', '.records_discard', function() {
	var b = $(this); b.prop('disabled', true).text('…');
	$.post('/manager/records/fixes_discard', { uuid: b.attr('uuid') }, function() { recordsRender(); });
});
// put one finding to the Coding agent and keep the exchange on screen; each turn
// sends the transcript so far, so a follow-up question has the context
$(document).on('click', '.records_ask', function() {
	var b = $(this), area = b.closest('.records_ask_area');
	var qi = area.find('.records_ask_q'), ans = area.find('.records_answer');
	var question = qi.val() || '';
	var history = ans.attr('convo') || '';
	qi.val('');
	b.prop('disabled', true).text('…');
	ans.text((history ? history + '\n' : '') + 'You: ' + question + '\nAgent: thinking…');
	$.post('/manager/records/fixes_ask', { uuid: b.attr('uuid'), question: question, history: history }, function(res) {
		var answer = (res && res.answer) ? res.answer : '(no answer)';
		var convo = (history ? history + '\n' : '') + 'You: ' + question + '\nAgent: ' + answer;
		ans.attr('convo', convo).text(convo);
		b.prop('disabled', false).text('Ask');
	}).fail(function() {
		ans.text(history);
		b.prop('disabled', false).text('Ask');
	});
});
$(document).on('keydown', '.records_ask_q', function(e) {
	if (e.which === 13) { $(this).closest('.records_ask_area').find('.records_ask').trigger('click'); }
});
// a class the person knows is really long: silence the audit for that app
$(document).on('click', '.records_leave_app', function() {
	var b = $(this), app = b.attr('app');
	if (app && !confirm('Leave "' + app + '" alone? The records audit will stop reporting it.')) { return; }
	b.prop('disabled', true).text('…');
	$.post('/manager/records/fixes_exempt', { uuid: b.attr('uuid'), app: app }, function() { recordsRender(); });
});
$(document).on('click', '#records_scan_now', function() {
	var s = $(this); s.text('scanning…');
	$.post('/manager/records/scan', {}, function() {
		s.text('scan now');
		recordsRender();
	});
});
$(document).on('click', '#records_fixed_open', function() {
	var list = $('#records_fixed_list');
	if (list.is(':visible')) { list.hide(); return; }
	list.show().html('Loading…');
	$.get('/manager/records/fixes_fixed', function(res) {
		var rows = (res && res.fixed) || [];
		if (!rows.length) { list.html('<div style="opacity:.6;">Nothing fixed yet.</div>'); return; }
		list.html('');
		$.each(rows, function(i, f) {
			list.append($('<div style="padding:4px 0;border-top:1px solid var(--line);"></div>').text((f.kind || '') + ' · ' + (f.app || '') + ' — ' + (f.sample || '') + ' — ' + (f.note || '')));
		});
	}).fail(function() { list.html('<div style="opacity:.6;">Could not load the list.</div>'); });
});

// ---- the Plat page's sub-tabs (AI / OAuth2 / Crypto) -----------------------
// The tab is remembered per device, so reopening Plat returns to where the
// person left it.
function jawnosPlatTabShow(tab, save) {
	if (!tab) { return; }
	$('#plat_setting_list .cfg_tab_toggle').removeClass('active');
	$('#plat_setting_list .cfg_tab_toggle[tab="' + tab + '"]').addClass('active');
	$('#plat_setting_list .cfg_tab_panel').hide();
	$('#' + tab).show();
	if (save) { settingSetter({ app: '__president', setting: 'plat_tab', value: tab }); }
}
$(document).on('click', '#plat_setting_list .cfg_tab_toggle', function() {
	jawnosPlatTabShow($(this).attr('tab'), true);
});

function oauthPanelRefresh() {
	$.get('/manager/configure/oauth_panel', function(r) { $('#plat_oauth').html(r); });
}
$(document).on('click', '#oauth_client_add', function() {
	$.post('/manager/configure/oauth_client/add', {}, function() {
		jawnosPlatTabShow('plat_oauth', true);
		oauthPanelRefresh();
	});
});
$(document).on('click', '.oauth_client_remove', function() {
	$.post('/manager/configure/oauth_client/remove', { uuid: $(this).attr('uuid') }, function() { oauthPanelRefresh(); });
});
$(document).on('change', '.oauth_client_field', function() {
	var t = $(this);
	var field = t.attr('field');
	if (field === 'client_secret' && !t.val()) { return; }
	$.post('/manager/configure/oauth_client/save', { uuid: t.attr('uuid'), field: field, value: t.val() }, function() {
		if (field === 'client_secret') { oauthPanelRefresh(); }
	});
});

// ---- DNS (Configure -> Plat -> DNS) ----------------------------------------
// The credential a wildcard certificate is issued through. A token is sealed
// server-side and never returned, so a saved secret shows as "set" and a blank
// field leaves it alone. Changing the provider drops the old provider's secrets.
function dnsPanelRefresh() {
	$.get('/manager/configure/dns_panel', function(r) { $('#plat_dns').html(r); });
}
$(document).on('click', '#dns_client_add', function() {
	$.post('/manager/configure/dns_client/add', {}, function() {
		jawnosPlatTabShow('plat_dns', true);
		dnsPanelRefresh();
	});
});
$(document).on('click', '.dns_client_remove', function() {
	$.post('/manager/configure/dns_client/remove', { uuid: $(this).attr('uuid') }, function() { dnsPanelRefresh(); });
});
$(document).on('change', '.dns_client_field', function() {
	var t = $(this);
	var field = t.attr('field');
	if ((field === 'token' || field === 'key' || field === 'secret') && !t.val()) { return; }
	$.post('/manager/configure/dns_client/save', { uuid: t.attr('uuid'), field: field, value: t.val() }, function() {
		if (field === 'provider' || field === 'token' || field === 'key' || field === 'secret') { dnsPanelRefresh(); }
	});
});
$(document).on('click', '.dns_client_test', function() {
	var uuid = $(this).attr('uuid');
	var status = $('.dns_client_status[uuid="' + uuid + '"]');
	status.text('testing…');
	$.post('/manager/configure/dns_client/test', { uuid: uuid }, function(r) {
		status.text((r && r.message) || (r && r.result) || 'no answer');
	}, 'json');
});
$(document).on('change', '#public_ip_check_select', function() {
	var status = $('#public_ip_check_status');
	status.text('saving…');
	settingSetter({ app: '__president', setting: 'public_ip_check', device: 'all', value: $(this).val() }).then(function() {
		status.text('saved');
		dnsPanelRefresh();
	});
});
$(document).on('click', '.dns_client_from_ai, .dns_client_to_ai', function() {
	var uuid = $(this).attr('uuid');
	var to_ai = $(this).hasClass('dns_client_to_ai');
	var status = $('.dns_client_status[uuid="' + uuid + '"]');
	$.post(to_ai ? '/manager/configure/dns_client/to_ai' : '/manager/configure/dns_client/from_ai', { uuid: uuid }, function(r) {
		status.text((r && r.message) || (r && r.result) || 'no answer');
		if (r && r.result === 'ok') { dnsPanelRefresh(); }
	}, 'json');
});
$(document).on('change', '#house_domain_input', function() {
	var status = $('#house_domain_status');
	status.text('saving…');
	$.post('/manager/configure/domain/house', { domain: $(this).val() }, function(r) {
		if (!r || r.result !== 'ok') { status.text((r && r.message) || 'could not save'); return; }
		status.text('saved');
		dnsPanelRefresh();
	}, 'json');
});
$(document).on('change', '.device_host_input', function() {
	var t = $(this);
	$.post('/manager/configure/domain/host', { signatorial: t.attr('signatorial'), host: t.val() }, function(r) {
		if (!r || r.result !== 'ok') { alert((r && r.message) || 'could not save'); return; }
		dnsPanelRefresh();
	}, 'json');
});
$(document).on('click', '#tls_issue_now', function() {
	var status = $('#tls_issue_status');
	status.text('issuing…');
	$.post('/manager/tls/issue', { signatorial: $(this).attr('signatorial') }, function(r) {
		if (!r || !r.ok) { status.text((r && r.error) || 'could not start'); return; }
		var poll = setInterval(function() {
			$.get('/manager/tls/status', function(s) {
				if (!s || !s.message) { return; }
				status.text('Last run: ' + (s.ok ? 'ok' : 'failed') + ' — ' + s.message);
				if (s.message !== 'issuing') { clearInterval(poll); }
			}, 'json');
		}, 3000);
	}, 'json');
});

// ---- crypto (Configure -> Plat -> Crypto) ----------------------------------
// Wallets are accounts; this page owns the asset list, the rate snapshot and the
// valuation. A wallet field saves to its own app and never leaves the panel.
// ---- pay (Configure -> Plat -> Pay) ----------------------------------------
// The Pay page is one panel: Crypto is its first section, then the hosted
// checkouts and Interac e-Transfer. Any change reloads the panel so a provider
// that just became ready is reflected at once.
function payPanelRefresh() {
	$.get('/manager/configure/pay_panel', function(r) { $('#plat_pay').html(r); });
}

function cryptoPanelRefresh() { payPanelRefresh(); }

function paySettingSave(setting, value, done) {
	$.post('/manager/pay/setting', {
		setting: setting, value: value, timestamp: Date.now()
	}, function(r) {
		if (!r || !r.ok) { alert((r && r.error) || 'could not save'); }
		if (done) { done(r); }
	}, 'json');
}

$(document).on('change', '.pay_setting', function() {
	var el = $(this);
	var setting = el.attr('setting');
	var value = el.attr('type') === 'checkbox' ? (el.prop('checked') ? 'on' : 'off') : el.val();
	paySettingSave(setting, value);
});

$(document).on('change', '.pay_secret', function() {
	var el = $(this);
	if (!el.val()) { return; }
	var setting = el.attr('setting');
	paySettingSave(setting, el.val(), function(r) {
		if (!r || !r.ok) { return; }
		el.val('').attr('placeholder', '••• set — type to replace');
		$('.pay_secret_clear[setting="' + setting + '"]').show();
	});
});

$(document).on('click', '.pay_secret_clear', function() {
	var setting = $(this).attr('setting');
	if (!confirm('Clear the saved value?')) { return; }
	paySettingSave(setting, '', function() { payPanelRefresh(); });
});

$(document).on('click', '.pay_test', function() {
	var btn = $(this);
	var provider = btn.attr('provider');
	var status = $('.pay_test_status[provider="' + provider + '"]');
	status.text('asking…');
	$.post('/manager/pay/test', { provider: provider, timestamp: Date.now() }, function(r) {
		status.text((r && r.message) || 'no answer');
	}, 'json').fail(function() { status.text('could not ask'); });
});

$(document).on('click', '#pay_interac_scan', function() {
	var status = $('#pay_interac_scan_status');
	status.text('reading…');
	$.post('/manager/pay/interac/scan', { timestamp: Date.now() }, function(r) {
		if (!r || !r.ok) { status.text((r && r.error) || 'could not read'); return; }
		status.text('read ' + r.found + ' notification' + (r.found === 1 ? '' : 's') + ' · staged ' + r.staged + ' · recorded ' + r.recorded);
		setTimeout(payPanelRefresh, 700);
	}, 'json').fail(function() { status.text('could not read'); });
});

$(document).on('click', '.pay_interac_record', function() {
	var scope = $(this).closest('.pay_interac_row');
	var status = scope.find('.pay_interac_status');
	status.text('recording…');
	$.post('/manager/pay/interac/record', {
		id: $(this).attr('receipt'),
		uuid: scope.find('.pay_interac_invoice').val() || '',
		timestamp: Date.now()
	}, function(r) {
		if (!r || !r.ok) { status.text((r && r.error) || 'could not record'); return; }
		status.text(r.duplicate ? 'already recorded' : 'recorded');
		setTimeout(payPanelRefresh, 700);
	}, 'json').fail(function() { status.text('could not record'); });
});

$(document).on('click', '.pay_interac_ignore', function() {
	var scope = $(this).closest('.pay_interac_row');
	var status = scope.find('.pay_interac_status');
	$.post('/manager/pay/interac/ignore', { id: $(this).attr('receipt'), timestamp: Date.now() }, function() {
		scope.remove();
	}, 'json');
});

$(document).on('click', '#pay_interac_token_new', function() {
	if (!confirm('Make a new forwarding token? Any service using the old URL will stop working.')) { return; }
	$.post('/manager/pay/interac/token', { timestamp: Date.now() }, function() { payPanelRefresh(); }, 'json');
});

function cryptoSettingSave(setting, value, done) {
	$.post('/manager/setting_setter', {
		app: 'crypto', setting: setting, value: value, device: 'all', timestamp: Date.now()
	}, function(r) {
		if (r && r.ok === 0) { alert(r.error || 'could not save'); }
		if (done) { done(r); }
	}, 'json');
}

$(document).on('change', '.crypto_setting', function() {
	var el = $(this);
	var setting = el.attr('setting');
	var value = el.attr('type') === 'checkbox' ? (el.prop('checked') ? 'on' : 'off') : el.val();
	cryptoSettingSave(setting, value, function() { cryptoPanelRefresh(); });
});

$(document).on('change', '.crypto_asset_toggle', function() {
	var on = $('.crypto_asset_toggle:checked').map(function() { return $(this).val(); }).get();
	if (!on.length) { $(this).prop('checked', true); return; }
	cryptoSettingSave('assets', JSON.stringify(on), function() { cryptoPanelRefresh(); });
});

$(document).on('click', '#crypto_refresh', function() {
	var btn = $(this);
	btn.prop('disabled', true);
	$('#crypto_refresh_status').text('reading…');
	$.post('/manager/configure/crypto_refresh', { timestamp: Date.now() }, function(r) {
		btn.prop('disabled', false);
		$('#crypto_refresh_status').text(r && r.ok
			? ('read ' + r.count + ' rates from ' + r.source)
			: ((r && r.error) || 'no answer'));
		if (r && r.ok) { setTimeout(cryptoPanelRefresh, 900); }
	}, 'json').fail(function() {
		btn.prop('disabled', false);
		$('#crypto_refresh_status').text('no answer');
	});
});

// Every wallet field saves as it changes. This was a click handler on the copy
// button at one point, so the coin, address, label and xpub never reached the
// server. The copy button keeps its own handler below.
$(document).on('change', '.crypto_wallet_input', function() {
	var el = $(this);
	var app = el.attr('app');
	var status = $('.crypto_wallet_status[app="' + app + '"]');
	status.text('saving…');
	var payload = {
		app: app, setting: el.attr('setting'), value: el.val(), timestamp: Date.now()
	};
	// the xpub is the same on every machine: a phone must be able to derive
	// the invoice's address without the desktop that typed it
	if (el.attr('setting') === 'wallet_xpub') { payload.device = 'all'; }
	$.post('/manager/setting_setter', payload, function(r) {
		if (r && r.ok === 0) { status.text(r.error || 'could not save'); return; }
		status.text((r && r.note) ? r.note : 'saved');
	}, 'json').fail(function() { status.text('could not save'); });
});

$(document).on('click', '.crypto_wallet_copy', function() {
	var app = $(this).attr('app');
	var input = $('.crypto_wallet_address[app="' + app + '"]');
	if (!input.length) { return; }
	input.trigger('focus').trigger('select');
	try { document.execCommand('copy'); } catch (e) {}
});

// ---- History app type-ahead ------------------------------------------------
// A house has thousands of apps, so the panel does not ship them all: the query
// goes to the server and only the matching names come back.
var cryptoTrackSearch = null;

function cryptoTrackHideResults() {
	$('.crypto_tracking_app_results').hide().empty();
}

function cryptoTrackSave(value) {
	var status = $('.crypto_tracking_app_status');
	status.text('saving…');
	$.post('/manager/crypto/tracking_app', { value: value, timestamp: Date.now() }, function(r) {
		if (!r || !r.ok) { status.text((r && r.error) || 'could not save'); return; }
		$('.crypto_tracking_app_input').val(r.name || r.app || '');
		status.text(r.app
			? ('history goes to ' + (r.name || r.app))
			: 'follows the app that already holds currency measures');
		if (r.app) { setTimeout(cryptoPanelRefresh, 500); }
	}, 'json').fail(function() { status.text('could not save'); });
}

$(document).on('input', '.crypto_tracking_app_input', function() {
	var q = $.trim($(this).val());
	clearTimeout(cryptoTrackSearch);
	if (!q.length) { cryptoTrackHideResults(); return; }
	cryptoTrackSearch = setTimeout(function() {
		$.getJSON('/manager/crypto/apps', { q: q }, function(r) {
			var box = $('.crypto_tracking_app_results');
			box.empty();
			var list = (r && r.apps) || [];
			if (!list.length) { box.hide(); return; }
			list.forEach(function(a) {
				$('<div class="crypto_tracking_app_choice"></div>')
					.attr('data-app', a.app).attr('data-name', a.name)
					.css({ padding: '6px 9px', cursor: 'var(--jawnos-cursor-pointer, pointer)', 'border-bottom': '1px solid var(--line)' })
					.text(a.name + '  ·  ' + a.app)
					.appendTo(box);
			});
			box.show();
		});
	}, 120);
});

$(document).on('mousedown', '.crypto_tracking_app_choice', function(e) {
	e.preventDefault();
	var app = $(this).attr('data-app');
	$('.crypto_tracking_app_input').val($(this).attr('data-name'));
	cryptoTrackHideResults();
	cryptoTrackSave(app);
});

$(document).on('keydown', '.crypto_tracking_app_input', function(e) {
	if (e.key === 'Enter') {
		e.preventDefault();
		cryptoTrackHideResults();
		cryptoTrackSave($(this).val());
	}
	else if (e.key === 'Escape') {
		cryptoTrackHideResults();
	}
});

$(document).on('blur', '.crypto_tracking_app_input', function() {
	setTimeout(cryptoTrackHideResults, 160);
});

// ---- payment proof builder -------------------------------------------------
// The payer signs what was sent, naming the seller's crest. The code travels as
// PAY1Z: text (or its QR) and the seller verifies and countersigns it.
$(document).on('click', '#crypto_proof_build', function() {
	var status = $('#crypto_proof_status');
	var data = {
		payee: $.trim($('#crypto_proof_payee').val()),
		ref: $.trim($('#crypto_proof_ref').val()),
		asset: $('#crypto_proof_asset').val(),
		amount: $('#crypto_proof_amount').val(),
		address: $.trim($('#crypto_proof_address').val()),
		txid: $.trim($('#crypto_proof_txid').val()),
		memo: $('#crypto_proof_memo').val(),
		timestamp: Date.now()
	};
	status.text('signing…');
	$.post('/manager/crypto/proof_build', data, function(r) {
		if (!r || !r.ok) { status.text((r && r.error) || 'could not sign'); return; }
		$('#crypto_proof_code').val(r.code).show();
		$('#crypto_proof_actions').show();
		status.text('signed by ' + ((r.payer && r.payer.name) || 'this house') + (r.payee && r.payee.name ? ' for ' + r.payee.name : ''));
		$('#crypto_proof_result').text((r.verified ? 'signature checks' : 'signature did not check') + ' · ' + r.code.length + ' characters');
		var qr = $('#crypto_proof_qr');
		if (r.code.length <= 1200) { qr.attr('src', '/manager/crypto/qr?text=' + encodeURIComponent(r.code)).show(); }
		else { qr.removeAttr('src').hide(); }
	}, 'json').fail(function() { status.text('could not sign'); });
});

$(document).on('click', '#crypto_proof_copy', function() {
	var code = $('#crypto_proof_code').val();
	if (!code) { return; }
	$('#crypto_proof_code').trigger('focus').trigger('select');
	try { document.execCommand('copy'); } catch (e) {}
	$('#crypto_proof_result').text('copied');
});
