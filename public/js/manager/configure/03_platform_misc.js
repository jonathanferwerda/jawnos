$(document).on('click', '#misc_setting', function() {
	var b = $(this);
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/misc_setting_list',
		type:'GET',
		data: { timestamp: timestamp },
		success: function(response){
			$('#misc_setting_list').html(response);
			if (jawnosConfigureShow('misc_setting', $('#misc_setting_list'))) {
				b.attr('status', 'active');
			}
		}
	});
});

$(document).on('click', '#plat_setting', function() {
		var b = $(this);
		var timestamp = Date.now();
		$.ajax({
			url: '/manager/configure/plat_setting_list',
			type:'GET',
			data: { timestamp: timestamp },
			success: function(response){
				$('#plat_setting_list').html(response);
				if (jawnosConfigureShow('plat_setting', $('#plat_setting_list'))) {
					b.attr('status', 'active');
				}
				// the panel may remember the QA tab; ask the chosen machine once the
				// markup is in place (qaRefresh comes from 07_qa_nightly.js)
				if (typeof qaRefresh === 'function' && $('#plat_qa').is(':visible')) { qaRefresh(); }
			}
		});
	});

// the thinking choice rides beside an agent's model and is shown only while the
// chosen model is one that reasons; each option carries what it thinks, so the
// row moves with the pick (the stored level is kept either way). The fallback
// select mirrors the model list minus the primary, so it follows the pick too.
$(document).on('change', '.ai_role_model', function() {
	var role = $(this).closest('.ai_role');
	var thinks = $(this).find('option:selected').data('thinks');
	role.find('.ai_thinking_row').toggle(!!thinks);
	var primary = $(this).val();
	var fb = role.find('.ai_role_fallback');
	fb.find('option').each(function() {
		var o = $(this);
		o.prop('disabled', o.val() !== '' && o.val() === primary);
	});
	if (fb.val() === primary) { fb.val(''); }
});

// the Speech setting's Preview button: speak a test phrase in the voice chosen
// for that device, rather than waiting for a real say_it to happen
$(document).on('click', '.say_voice_test', function() {
	var voice = $(this).closest('.misc_device_block').find('.misc_setting[setting="say_voice"]').val();
	$.ajax({
		url: '/manager/say_it',
		type: 'GET',
		data: { words: 'This is the voice you have chosen.', voice: voice, timestamp: Date.now() }
	});
});

// The on-demand translation engine, from Configure -> Misc. It translates the
// visible window through the Guide's model and caches the result.
$(document).on('click', '#translate_window', function () {
	var to = $('#translate_target').val();
	var status = $('#translate_status');
	if (typeof jawnosTranslatePage !== 'function') {
		status.text('The translator is not loaded. Refresh and try again.');
		return;
	}
	status.text('Translating…');
	jawnosTranslatePage(to, function (r) {
		status.text('Translated ' + ((r.translated || 0) + (r.cached || 0)) + ' strings into ' + (r.to.native || r.to.name) + '.');
	}, function (r) {
		status.text((r && r.error) || 'Could not translate this window.');
	});
});

$(document).on('click', '#translate_clear', function () {
	try { localStorage.removeItem('jawnos_translation_target'); } catch (e) {}
	location.reload();
});

$(document).on('change','.misc_setting', function() {
	var timestamp = Date.now();
	var set = $(this);
	var setting = set.attr('setting');
	var object = set.attr('object');
	var dev = set.attr('device');
	var value = set.val();
	if (set.attr('type') == 'checkbox') {
		if (set.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off'
		}
	}
	var anchor = $('.anchor_all_settings[setting_type="misc"]');
	var anchor_check = anchor.is(':checked');
	if (anchor_check == true) {
		anchor.prop('checked', false);
		$('.misc_setting[setting="' + setting + '"]').each(function(i,v) {
			if ($(v).attr('device') != dev) {
				if ($(v).attr('type') == 'checkbox') {
					$(v).prop('checked', set.prop('checked'));
				}
				$(v).val(value)
				$(v).trigger('change');
			}
		});
		setTimeout(function() {
			anchor.prop('checked', true);
		},1000);
	}
	$.ajax({
		url: '/manager/configure/misc_setting',
		type: 'POST',
		data: { timestamp: timestamp, 
			setting: setting, 
			value: value, 
			device: dev,
			timestamp: timestamp
		},
		success: function(response) {
			$.each(response, function(i,v) {
				if (v.setting == 'language') {
					// the whole interface is server-rendered in the chosen
					// language, so the new labels arrive with a fresh page
					location.reload();
					return false;
				}
				if (v.setting == 'manager_background_colour' && dev == v.device) {
					// a running appointment theme owns the desktop until it stops
					if ($('body').attr('data-appt-theme') != 'yes') {
						$('body').css({'background-color':v.value});
						if (typeof jawnosApplyInk == 'function') { jawnosApplyInk(); }
					}
				}
				if (v.setting == 'configure_background_colour' && dev == v.device) {
					$('#configure').css({'background-color': v.value});
				}
				if (v.setting == 'title_font' && dev == v.device) {
					// the shell reads the family off the root, so one property updates
					// every surface and control; the canvas clothesline is repainted by
					// hand because it cannot inherit a CSS face
					document.documentElement.style.setProperty('--jawnos-font', v.value);
					$('.title_font').css({'font-family': v.value});
					if (typeof clotheslineHanger == 'function' && typeof wardrobe != 'undefined' && wardrobe && wardrobe.length) {
						clotheslineHanger(wardrobe);
					}
				}
				if ($('#' + object)) {
					$('#' + object).css({'background-color': value});
				}
				if ($('.' + object).length > 0) {
					$('.' + object).css({'background-color': value});
				}
				$('.misc_setting[device="' + v.device + '"][setting="' + v.setting + '"]').val(v.value);
			});
		}

	});

});

// The Corner Radius slider's Follow theme button, shown while a theme is in
// charge: it drops the explicit override so the theme's own corner comes back.
$(document).on('click', '#corner_follow_theme', function () {
	var device = $(this).attr('device');
	var corner = parseInt($(this).attr('theme_corner'), 10);
	if (isNaN(corner)) { corner = 12; }
	var slider = $('.misc_setting[setting="corner_override"][device="' + device + '"]');
	slider.val(corner);
	var readout = document.getElementById('corner_override_value_' + device);
	if (readout) { readout.textContent = corner; }
	if (typeof jawnosCornerApply == 'function') { jawnosCornerApply(corner, true); }
	$.ajax({
		url: '/manager/configure/misc_setting',
		type: 'POST',
		data: { setting: 'corner_override', value: '', device: device, timestamp: Date.now() }
	});
});

$(document).on('change','.sys_setting', function() {
	var timestamp = Date.now();
	var set = $(this);
	var setting = set.attr('setting');
	var object = set.attr('object');
	var dev = set.attr('device');
	var value = set.val();
	if (set.attr('type') == 'checkbox') {
		if (set.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off'
		}
	}
	var anchor = $('.anchor_all_settings[setting_type="sys"]');
	var anchor_check = anchor.is(':checked');
	if (anchor_check == true) {
		anchor.prop('checked', false);
		$('.misc_setting[setting="' + setting + '"]').each(function(i,v) {
			if ($(v).attr('device') != dev) {
				if ($(v).attr('type') == 'checkbox') {
					$(v).prop('checked', set.prop('checked'));
				}
				$(v).val(value)
				$(v).trigger('change');
			}
		});
		setTimeout(function() {
			anchor.prop('checked', true);
		},1000);
	}
	$.ajax({
		url: '/manager/configure/sys_setting',
		type: 'POST',
		data: { timestamp: timestamp, 
			setting: setting, 
			value: value, 
			device: dev,
			timestamp: timestamp
		},
		success: function(response) {
		}
	});
});

$(document).on('change', '.utility_controller', function() {
	var b = $(this);
	var control = b.attr('control');
	var device = b.attr('device');
	var setting = b.attr('setting');
	var value = b.val();

	if (b.attr('type') == 'checkbox') {
		if (b.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off';
		}
	}
	$.ajax({
		url: '/manager/configure/utility_controller/save',
		type: 'POST',
		data: { control: control, device: device, value: value, setting: setting },
		success: function(response) {
			$('#utility_controls_container').html(response.html);
		},
		error: function(e) {
			// a failed save must not leave the switch reading the value we tried to set
			// (the 5s reloader would then look like the toggle unchecked itself) -
			// repaint from the server; the error dot names the failure
			utilityControllerReloader();
		}
	});
});

// The batch pools. The editor is one drop zone per pool plus a regular bin. The
// whole state is saved at once, so a drag, a rename, a pace and a removal all
// take the same route and the panel repaints from what the server stored.
function utilityPoolState() {
	var pools = [];
	$('#utility_pools .utility_pool').each(function() {
		var card = $(this);
		var id = card.attr('data-pool');
		if (!id) { return; }
		pools.push({
			id: id,
			label: $.trim(card.find('.utility_pool_label').val() || '') || id,
			seconds: $.trim(card.find('.utility_pool_seconds').val() || '')
		});
	});
	var members = {};
	$('#utility_pools .utility_chip').each(function() {
		members[$(this).attr('data-job')] = $(this).closest('.utility_pool_members').attr('data-pool') || '';
	});
	return { pools: pools, members: members };
}

function utilityPoolsSave(pools, members) {
	var state = utilityPoolState();
	var data = {
		pools: JSON.stringify(pools || state.pools),
		members: JSON.stringify(members || state.members)
	};
	$.ajax({
		url: '/manager/configure/utility_pools/save',
		type: 'POST',
		data: data,
		success: function(response) {
			if (response && response.html) {
				$('#utility_controls_container').html(response.html);
				appointment_chron();
			}
			else { utilityControllerReloader(); }
		},
		error: function() { utilityControllerReloader(); }
	});
}

function utilityPoolPlace(chip, poolId) {
	var zone = $('#utility_pools .utility_pool_members').filter(function() {
		return ($(this).attr('data-pool') || '') === (poolId || '');
	}).first();
	if (!zone.length) { return; }
	zone.find('.utility_pool_empty').remove();
	chip.appendTo(zone);
	utilityPoolsSave();
}

$(document).on('change', '.utility_pool_seconds, .utility_pool_label', function() {
	// A pace that does not parse is put back rather than saved as zero; the
	// server's own check is the second line of defence.
	var input = $(this);
	if (input.hasClass('utility_pool_seconds') && !$.trim(input.val())) {
		utilityControllerReloader();
		return;
	}
	utilityPoolsSave();
});

$(document).on('click', '.utility_pool_add_button', function() {
	var input = $('#utility_batch_groups .utility_pool_new_name');
	var label = $.trim(input.val() || '');
	if (!label) { input.focus(); return; }
	var base = label.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'pool';
	var id = base, n = 2;
	while ($('#utility_pools .utility_pool[data-pool="' + id + '"]').length) { id = base + '_' + (n++); }
	var state = utilityPoolState();
	state.pools.push({ id: id, label: label, seconds: '15m' });
	utilityPoolsSave(state.pools, state.members);
});

$(document).on('keydown', '#utility_batch_groups .utility_pool_new_name', function(e) {
	if (e.key === 'Enter') { e.preventDefault(); $(this).closest('#utility_batch_groups').find('.utility_pool_add_button').trigger('click'); }
});

$(document).on('click', '.utility_pool_remove', function() {
	var id = $(this).attr('data-pool');
	var state = utilityPoolState();
	state.pools = $.grep(state.pools, function(pool) { return pool.id !== id; });
	$.each(state.members, function(job, pool) {
		if (pool === id) { state.members[job] = ''; }
	});
	utilityPoolsSave(state.pools, state.members);
});

// Mouse drag and drop.
$(document).on('dragstart', '.utility_chip', function(e) {
	var ev = e.originalEvent;
	if (!ev.dataTransfer) { return; }
	ev.dataTransfer.setData('text/plain', $(this).attr('data-job'));
	ev.dataTransfer.effectAllowed = 'move';
	$(this).addClass('utility_chip_dragging');
});

$(document).on('dragend', '.utility_chip', function() {
	$(this).removeClass('utility_chip_dragging');
	$('.utility_pool_members').removeClass('utility_pool_over');
});

$(document).on('dragover', '.utility_pool_members', function(e) {
	e.preventDefault();
	if (e.originalEvent.dataTransfer) { e.originalEvent.dataTransfer.dropEffect = 'move'; }
	$('.utility_pool_members').removeClass('utility_pool_over');
	$(this).addClass('utility_pool_over');
});

$(document).on('dragleave', '.utility_pool_members', function() {
	$(this).removeClass('utility_pool_over');
});

$(document).on('drop', '.utility_pool_members', function(e) {
	e.preventDefault();
	var job = e.originalEvent.dataTransfer ? e.originalEvent.dataTransfer.getData('text/plain') : '';
	var chip = $('.utility_chip').filter(function() { return $(this).attr('data-job') === job; }).first();
	$(this).removeClass('utility_pool_over');
	if (chip.length) { utilityPoolPlace(chip, $(this).attr('data-pool') || ''); }
});

// Touch drag and drop: a finger that moves past a few pixels lifts the chip and
// follows it; a tap that stays still leaves the switch inside the chip to work.
var utilityPoolDrag = null;
$(document).on('pointerdown', '.utility_chip', function(e) {
	if (e.originalEvent.pointerType === 'mouse') { return; }
	if ($(e.target).is('input, img')) { return; }
	utilityPoolDrag = {
		chip: $(this),
		id: e.originalEvent.pointerId,
		x: e.originalEvent.clientX,
		y: e.originalEvent.clientY,
		moving: false
	};
});

$(document).on('pointermove', '.utility_chip', function(e) {
	if (!utilityPoolDrag || utilityPoolDrag.chip[0] !== this || utilityPoolDrag.id !== e.originalEvent.pointerId) { return; }
	var dx = e.originalEvent.clientX - utilityPoolDrag.x;
	var dy = e.originalEvent.clientY - utilityPoolDrag.y;
	if (!utilityPoolDrag.moving && Math.abs(dx) + Math.abs(dy) < 8) { return; }
	utilityPoolDrag.moving = true;
	e.preventDefault();
	utilityPoolDrag.chip.addClass('utility_chip_dragging');
	$('.utility_pool_members').removeClass('utility_pool_over');
	var zone = $(document.elementFromPoint(e.originalEvent.clientX, e.originalEvent.clientY)).closest('.utility_pool_members');
	if (zone.length) { zone.addClass('utility_pool_over'); }
});

$(document).on('pointerup pointercancel', '.utility_chip', function(e) {
	if (!utilityPoolDrag || utilityPoolDrag.chip[0] !== this || utilityPoolDrag.id !== e.originalEvent.pointerId) { return; }
	var drag = utilityPoolDrag;
	utilityPoolDrag = null;
	drag.chip.removeClass('utility_chip_dragging');
	$('.utility_pool_members').removeClass('utility_pool_over');
	if (!drag.moving) { return; }
	e.preventDefault();
	var zone = $(document.elementFromPoint(e.originalEvent.clientX, e.originalEvent.clientY)).closest('.utility_pool_members');
	if (zone.length) { utilityPoolPlace(drag.chip, zone.attr('data-pool') || ''); }
});

function utilityControllerReloader() {
	$.ajax({
		url: '/manager/configure/utility_controller',
		type: 'GET',
		data: {  },
		success: function(response) {
			$('#utility_controls_container').html(response.html);
			appointment_chron();
		}
	});
}


$(document).on('change', '.device_domain', function() {
	var b = $(this);
	var timestamp = b.attr('timestamp');
	var domain = b.val();
	var device = b.attr('device');
	var address = b.attr('address');
	var uuid = b.attr('uuid');
	$.ajax({
		url: '/manager/configure/device_domain_updater',
		type: 'POST',
		data: { 
			device: device,
			domain: domain,
			timestamp: timestamp, 
			uuid: uuid
		}
	});
});

$(document).on('click','.delete_device', function() {
	var a = $(this);
	var device = a.attr('device');
	var timestamp = a.attr('timestamp');
	var uuid = a.attr('uuid');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/configure/device_deleter',
			type: 'POST',
			data: { device: device, timestamp: timestamp, uuid: uuid },
			success:function(response) {
				$('.device[uuid="' + uuid + '"]').remove();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click', '.delete_neighbour_device', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var rm = a.closest('.remote_machine');
	var rm_uuid = a.attr('rm_uuid');
	var device = a.closest('.device');
	var device_uuid = device.attr('uuid');

	if (a.attr('armed') == 'yes') {
		a.attr('armed','pending');
		$.ajax({ 
			url: '/manager/configure/device/neighbour_delete',
			data: { device_uuid: device_uuid, uuid: uuid, rm_uuid: rm_uuid },
			type: 'POST',
			success: function(response) {
				rm.remove();
				a.css({'background-color': 'lightgreen' });
				setTimeout(function() {
					a.attr('armed', 'no');
					var obg = a.attr('obg');
					a.css({'background-color': obg });
				},2000);
			}
		});
	}
	else if (a.attr('armed') != 'pending') {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.attr('obg', bgcolor);
		a.css({'background-color': 'orange' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click','#stop_all', function() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/stop_all_appointments',
		type:'POST',
		data: { timestamp: timestamp },
		success:function(response) {

		}
	});
});

$(document).on('click', '#me_settings', function() {
	var timestamp = Date.now();
	var b = $(this);
	var ml = $('#me_setting_list');
	$.ajax({
		url: '/manager/configure/me_settings',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			ml.html(response);
			if (jawnosConfigureShow('me_settings', ml)) {
				b.attr('status', 'active');
			}
		}
	});
});

$(document).on('change', '.me_setting', function() {
	var set = $(this);
	var timestamp = Date.now();
	var setting = set.attr('setting');
	var dev = set.attr('device');
	var value = set.val();
	if (set.attr('type') == 'checkbox') {
		if (set.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off'
		}
	}
	var anchor = $('.anchor_all_settings[setting_type="me"]');
	var anchor_check = anchor.is(':checked');
	if (anchor_check == true) {
		anchor.prop('checked', false);
		$('.me_setting[setting="' + setting + '"]').each(function(i,v) {
			if ($(v).attr('device') != dev) {
				if ($(v).attr('type') == 'checkbox') {
					$(v).prop('checked', set.prop('checked'));
				}
				$(v).val(value)
				$(v).trigger('change');
			}
		});
		setTimeout(function() {
			anchor.prop('checked', true);
		},1000);
	}
	$.ajax({
		url: '/manager/configure/me_setting',
		type: 'POST',
		data: { 
			timestamp: timestamp, 
			setting: setting, 
			value: value, 
			device: dev,
			timestamp: timestamp
		},
		success: function(response) {
			if (response.setting == 'my_name') {
				my_name = response['value'];
			}
		}
	});
});

$(document).on('click', '.home_plate_record', function() {
	var device = $(this).attr('device');
	var timestamp = Date.now();
	continent_record({device: device, app:'me', timestamp:timestamp,purpose:'home_plate'});
});

$(document).on('click', '#restore_list', function() {
	var c = $('#backup_list');
	var b = $(this);
	var text = jawnosConfigureLabel(b);
	b.text('* ' + text);
	var president = $('#president').val();
	$.ajax({
		url: '/manager/configure/restore_list',
		type: 'GET',
		data: { 'president': president },
		success:function(response) {
			c.html(response);
			if (jawnosConfigureShow('restore_list', c)) {
				b.text(text);
				b.attr('status', 'active');
			}
		}
	});
});

$(document).on('click', '#system_setting_lister', function() {
	var c = $('#system_list');
	var b = $(this);
	var text = jawnosConfigureLabel(b);
	var local_storage = JSON.stringify(localStorage);
	b.text('* ' + text);
	$.ajax({
		url: '/manager/configure/system_list',
		// POST: localStorage can be large, and in a GET query it would blow the
		// manager's 64k request-line cap and the panel would come back as the Gate
		type: 'POST',
		data: { local_storage: local_storage },
		success: function(response) {
			c.html(response);
			if (typeof jawnosBalanceWindowRestore === 'function') { jawnosBalanceWindowRestore(c[0]); }
			if (jawnosConfigureShow('system_setting_lister', c)) {
				b.text(text);
				b.attr('status', 'active');
			}
		},
		error: function(e) {
			b.text(jawnosConfigureLabel(b));
			c.html('<div class="cfg-note">the Sys panel did not load (' + e.status + '); press Sys to try again</div>').show();
		}
	});
});

// The API balance chart keeps one plot per window: the last hour in two-minute
// bars, the last day in hours, the last week and the last month in days. All of
// them are drawn from the same background samples, so switching is a show/hide
// and never another provider read. The choice is kept per browser so reopening
// Sys returns to the window last used; a window stored by the older three-button
// chart is mapped onto the one that means the same span.
function jawnosBalanceWindowPick(scope, win) {
	$(scope).find('.balance_window').removeAttr('status');
	$(scope).find('.balance_window[window="' + win + '"]').attr('status', 'active');
	$(scope).find('.balance_plot').each(function () {
		$(this).css('display', ($(this).attr('window') || '') === win ? '' : 'none');
	});
}
function jawnosBalanceWindowRestore(root) {
	var win = '1d';
	try { win = localStorage.getItem('jawnos:balance_window') || '1d'; } catch (e) {}
	if (win === '24h') { win = '1d'; }
	if (win === '7d') { win = '1w'; }
	var scope = (root && root.querySelectorAll) ? root : document;
	var charts = scope.querySelectorAll ? scope.querySelectorAll('.balance_chart') : [];
	for (var i = 0; i < charts.length; i++) {
		if (!charts[i].querySelector('.balance_window[window="' + win + '"]')) { win = '1d'; }
		jawnosBalanceWindowPick(charts[i], win);
	}
}
$(document).on('click', '.balance_window', function() {
	var button = $(this);
	var chart = button.closest('.balance_chart');
	var win = button.attr('window') || '1d';
	jawnosBalanceWindowPick(chart, win);
	try { localStorage.setItem('jawnos:balance_window', win); } catch (e) {}
});

// Pressing a bar opens that bar's line under the chart - its drop, its share of
// the window, the tokens and calls behind it, and the models that used them -
// and pressing the same bar again closes it. The words come from templates
// rendered onto the drawing, so this only decides which bar is lit and lets the
// currency helper fill in the numbers.
$(document).on('click', '.balance_bars rect.hit', function() {
	var hit = $(this);
	var plot = hit.closest('.balance_plot');
	var series = hit.closest('.balance_series');
	var key = hit.attr('data-bk') || '';
	var lit = plot.find('.balance_bars rect.picked').not('.hit').first();
	var wasOpen = lit.length && (lit.attr('data-bk') || '') === key;
	plot.find('.balance_bars rect.picked').removeClass('picked');
	plot.find('.balance_bucket_detail').hide().text('');
	if (wasOpen) { return; }
	plot.find('.balance_bars rect[data-bk]').not('.hit').filter(function() {
		return ($(this).attr('data-bk') || '') === key;
	}).addClass('picked');
	if (typeof jawnosBalanceBucketRefresh === 'function') { jawnosBalanceBucketRefresh(series[0]); }
});

