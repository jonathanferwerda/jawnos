/* [[js-split]]
   configure.js is part 1. The rest live in configure/ in name order:
     01_update_controls.js  - update button, notification sound, guide verbs, budgets, measures, packaging, ping, device scan
     02_remote_devices.js   - tunnels, pseudonyms, store, device purpose, ping, neighbours, remote machines, migration
     03_platform_misc.js    - misc/Plat settings, AI role, speech, translate, themes, utility pools, devices, balance window
     04_currency_backup.js  - currency amounts, backup/merge/new database, adopt, doctor, uploads, tickets, signatorial
     05_database_records.js - vacuum, uuid cleaner, QR, distance, home plate, NFC, contacts, rename-merge, records watch
     06_watch_pay.js        - Plat sub-tabs, DNS, crypto, pay, History type-ahead, payment proof
     07_qa_nightly.js       - Plat's QA tab: the nightly device, its readiness and the install
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
var global_constraints = { 'video': false, 'audio': false };
var configIntervals = { 'sysEvaluateInterval': '', 'sysEvaluateTimeout' : '' };

// The Configure tabs behave like tabs: opening one panel closes the others, so
// there is never a tall pile of half-scrolled panels. This runs before each
// panel's own handler and makes the pressed tab the intent, so the panel may
// show itself when its load lands. Clicking the tab that is already open asks
// that panel to refresh in place rather than hiding it.
var jawnos_configure_panels = {
	me_settings: 'me_setting_list',
	restore_list: 'backup_list',
	system_setting_lister: 'system_list',
	misc_setting: 'misc_setting_list',
	plat_setting: 'plat_setting_list',
	appointment_list_grabber: 'configure_appointment_list',
	device_lister: 'device_list',
	tunnel_lister: 'tunnel_list',
	pseudonym_setting_lister: 'pseudonym_list',
	store_setting_lister: 'store_list'
};
// A tab's true label, captured once the first time we see it, so a panel that
// closes can put its button back exactly as it was when the screen loaded --
// even if a load was still in flight and left a '* loading' prefix behind.
function jawnosConfigureLabel(b) {
	var label = b.attr('data-label');
	if (!label) {
		label = (b.text() || '').replace(/^(\*\s*)+/, '').trim();
		b.attr('data-label', label);
	}
	return label;
}
function jawnosConfigureLabelAll() {
	$('.configure_toggle').each(function() {
		if (!$(this).attr('data-label')) {
			$(this).attr('data-label', ($(this).text() || '').replace(/^(\*\s*)+/, '').trim());
		}
	});
}
// Which tab the user last asked for. A panel's own load may finish after the
// user has moved on; it only gets to show itself if it is still the intent, so
// a slow panel can never stack a second one on screen.
var jawnos_configure_intent = null;
function jawnosConfigureShow(buttonId, c) {
	if (jawnos_configure_intent !== buttonId) { return false; }
	c.show();
	return true;
}
$(document).on('click', '.configure_toggle', function() {
	var b = $(this);
	var keep = jawnos_configure_panels[this.id];
	if (!keep) { return; }
	jawnosConfigureLabel(b);
	// Even a tab that is already open stays the intent: its handler reloads the
	// panel and gets to show it again when the new content arrives.
	jawnos_configure_intent = this.id;
	// Moving to another panel starts at its top. Refreshing the panel already on
	// screen keeps the reader where they were.
	if (!$('#' + keep).is(':visible')) { jawnosConfigureScrollTop(0); }
	$.each(jawnos_configure_panels, function(button, panel) {
		if (panel === keep) { return; }
		$('#' + panel).hide();
		$('#' + button).attr('status', 'inactive').text(jawnosConfigureLabel($('#' + button)));
	});
});

// ---- the pinned bar and the scroll it follows ---------------------------------
// The bar steps out of the way while a panel is read downward and returns the
// moment the scroll turns back up; at the top it is always shown. Listen in the
// capture phase because scroll does not bubble, and from the document because
// #configure is re-created whenever the window is re-rendered (an icon-set
// change, say) - one listener outlives every copy of the panel.
window.jawnos_configure_bar_last = 0;
document.addEventListener('scroll', function(event) {
	var el = event.target;
	if (!el || el.id !== 'configure') { return; }
	var top = el.scrollTop || 0;
	var last = window.jawnos_configure_bar_last || 0;
	window.jawnos_configure_bar_last = top;
	var bar = el.querySelector('.cfg_topbar');
	if (!bar) { return; }
	// Until the bar's own flow space has scrolled away, hiding it would leave a
	// gap where it used to sit; only tuck it away once it is fully past the top.
	var limit = (bar.offsetHeight || 40) + 8;
	if (top <= limit) { bar.classList.remove('cfg_topbar_hidden'); return; }
	if (top > last + 2) { bar.classList.add('cfg_topbar_hidden'); }
	else if (top < last - 2) { bar.classList.remove('cfg_topbar_hidden'); }
}, true);

// Put a panel at a known offset without the bar treating the jump as a downward
// read. Used by the tab switch (0) and by the window restore (the saved offset).
function jawnosConfigureScrollTop(top) {
	var el = $('#configure')[0];
	if (!el) { return; }
	el.scrollTop = top || 0;
	window.jawnos_configure_bar_last = el.scrollTop || 0;
	var bar = el.querySelector('.cfg_topbar');
	if (bar) { bar.classList.remove('cfg_topbar_hidden'); }
}

// The window restore reads the offset back from jopen and hands it here once the
// saved panel is on screen (windows.js calls this by name when it exists).
function jawnosConfigureScrollRestore(at) {
	jawnosConfigureScrollTop(at || 0);
	// Opening a section changes the panel's height, so the accordion state settles
	// after the saved offset is back in place, never before it.
	if (typeof jawnosAccRestore === 'function') { jawnosAccRestore(); }
}

// ---- collapsible Configure sections -----------------------------------------
// Contract, used by the *_setting_list templates and any partial that wants a
// collapsible block:
//
//   <details class="cfg-acc" data-acc="plat-ai" open>
//     <summary>Section title</summary>
//     ...section body...
//   </details>
//
// data-acc is a stable `<tab>-<section>` id and never the visible title, so a
// translation cannot move a stored choice. `open` is the first-render default.
// localStorage['jawnos:accordions'] is a JSON object of id -> 1 recording the
// sections the person has opened; an absent id keeps the markup default, so the
// map stays a whitelist. It is capped at jawnos_acc_max entries, which keeps an
// id that has left the markup from growing the map without bound.
var jawnos_acc_key = 'jawnos:accordions';
var jawnos_acc_max = 200;
var jawnos_acc_observer = null;
var jawnos_acc_panel = null;
var jawnos_acc_root_observer = null;

function jawnosAccRead() {
	var map = {};
	try {
		map = JSON.parse(localStorage.getItem(jawnos_acc_key) || '{}');
	}
	catch (e) { map = {}; }
	return (map && typeof map === 'object' && !(map instanceof Array)) ? map : {};
}

function jawnosAccWrite(map) {
	var keys = Object.keys(map);
	while (keys.length > jawnos_acc_max) { delete map[keys.shift()]; }
	try { localStorage.setItem(jawnos_acc_key, JSON.stringify(map)); } catch (e) {}
}

function jawnosAccRemember(id, open) {
	if (!id) { return; }
	var map = jawnosAccRead();
	if (open) { map[id] = 1; }
	else { delete map[id]; }
	jawnosAccWrite(map);
}

function jawnosAccBind(section) {
	if (section.jawnosAccBound) { return; }
	section.jawnosAccBound = true;
	// `toggle` does not bubble in WebKitGTK, so a delegated handler on document
	// would never see it: bind each section directly, exactly once.
	section.addEventListener('toggle', function () {
		jawnosAccRemember(this.getAttribute('data-acc'), this.open);
	});
}

// Apply the stored choices to every .cfg-acc under root. Idempotent and cheap:
// only the sections whose state actually differs are touched, and each section
// gets its toggle listener once.
function jawnosAccRestore(root) {
	var scope = (root && root.querySelectorAll) ? root : document;
	var sections = scope.querySelectorAll('details.cfg-acc');
	if (!sections.length) { return; }
	var map = jawnosAccRead();
	for (var i = 0; i < sections.length; i++) {
		var section = sections[i];
		var id = section.getAttribute('data-acc');
		if (!id) { continue; }
		// A stored choice wins; otherwise the markup's own `open` stands.
		if (Object.prototype.hasOwnProperty.call(map, id)) {
			var open = !!map[id];
			if (section.open !== open) { section.open = open; }
		}
		jawnosAccBind(section);
	}
}

// A panel's HTML arrives over AJAX and is swapped in, so the observer has to
// outlive each render. It watches #configure for added .cfg-acc nodes and
// restores in a microtask - after any synchronous scroll restore has run.
function jawnosAccWatch() {
	var panel = document.getElementById('configure');
	if (!panel || panel === jawnos_acc_panel) { return; }
	if (jawnos_acc_observer) { jawnos_acc_observer.disconnect(); }
	jawnos_acc_panel = panel;
	if (window.MutationObserver) {
		jawnos_acc_observer = new MutationObserver(function (records) {
			for (var i = 0; i < records.length; i++) {
				var added = records[i].addedNodes;
				for (var j = 0; j < added.length; j++) {
					var node = added[j];
					if (node.nodeType !== 1) { continue; }
					if ((node.matches && node.matches('details.cfg-acc')) || node.querySelector('details.cfg-acc')) {
						jawnosAccRestore(panel);
						return;
					}
				}
			}
		});
		jawnos_acc_observer.observe(panel, { childList: true, subtree: true });
	}
	jawnosAccRestore(panel);
}

function jawnosAccBoot() {
	jawnosAccWatch();
	// The window maker rebuilds the Configure shell (an icon-set change, say) and
	// the observer would go with the old copy. Watch the body for a fresh
	// #configure and re-bind. `open` is an attribute, not a child, so this never
	// sees the restore's own writes and cannot loop.
	if (window.MutationObserver && !jawnos_acc_root_observer) {
		jawnos_acc_root_observer = new MutationObserver(function (records) {
			for (var i = 0; i < records.length; i++) {
				var added = records[i].addedNodes;
				for (var j = 0; j < added.length; j++) {
					var node = added[j];
					if (node.nodeType !== 1) { continue; }
					if (node.id === 'configure' || (node.querySelector && node.querySelector('#configure'))) {
						jawnosAccWatch();
						return;
					}
				}
			}
		});
		jawnos_acc_root_observer.observe(document.body, { childList: true, subtree: true });
	}
}

$(jawnosAccBoot);

async function configureToggle() {
	var cb = $('#configure_balloon');
	if (cb.is(':visible')) {
		cb.hide();
	}
	else if (cb.find('#configure').length > 0) {
		cb.show();
	}
	else {
		var browser_tab_id = sessionStorage.getItem('browser_tab_id');
		var browser_tab = localStorage.getItem('browser_tab');
		$.ajax({
			url: '/manager/configure',
			type: 'GET',
			data: { 
				browser_tab_id: browser_tab_id,
				browser_tab: browser_tab
			},
			success: function(response) {
				//cb.show();
				//cb_check = 1;
				//cb.html(response);
				windowMaker(response);
				initializer();
				jawnosConfigureLabelAll();
			
				$('.media_picker').each(function(i,vd) {
					var v = $(vd);
					var type = v.attr('type');
					var kind = v.attr('kind');
					var device_id = v.attr('device_id');
					var mp = jawnosDevicePickGet(kind, device_id);
					if (mp == 'on') { v.attr('selected', 'on'); v.css({'background-color': 'green'}); }
				});
			}, error: function(response) { console.log(response); }
			
		});


	}
}

$(document).on('change', '.appointment_setting', function() {
	var setting = $(this).attr('setting');
	var value = $(this).val();
	if ($(this).is('select')) {
		value = JSON.stringify(value);
	}
	else if ($(this).attr('type') == 'checkbox') {
		if ($(this).prop('checked') == true) {
			value = 'on';
		}
		else {
			value == 'off';
		}
	}
	var app = $(this).attr('app') || $(this).closest('.appointment').attr('app') || $(this).closest('.wind').attr('app');
	var setter = { 'app': app, 'setting': setting, 'value': value };
	settingSetter(setter);
});

$(document).on('click', '.permission_asker', function() {
	permissionAsker();
});

async function permissionAsker(kind) {
	if (kind == 'location' || !kind) {
		// The app's GPS service, never navigator.geolocation: a WebView's
		// location answer carries no provider, so it cannot be told apart
		// from a Wi-Fi guess.
		if (window.JawnLocation && typeof window.JawnLocation.start === 'function') {
			window.JawnLocation.start();
		}
	}
	if (kind == 'media' || !kind) {
		var constraints = await constraintMaker();
		var av = await navigator.mediaDevices.enumerateDevices();
		var avData = JSON.stringify(av);

		$.ajax({
			url: '/manager/configure/permissions',
			type: 'POST',
			data: {
				avData: avData,
				constraints: constraints
			}
		});
	}
	if (kind == 'notifications' || !kind) {
		Notification.requestPermission().then((result) => {

		});
	}
	if ((kind == 'nfc' || !kind) && typeof jawnNfcAvailable === 'function' && jawnNfcAvailable()) {
		// Never mint a second reader: the first one stays armed in the
		// background, and two readers would report every tap twice.
		if (!nfc || !nfc['ndef']) {
			nfc = {
				scanning: false,
				writing: false,
				abort: new AbortController(),
				initialized: false,
				lastWrite: 0,
				lastReadKey: '',
				lastReadAt: 0
			};
			nfc['ndef'] = jawnNfcMake();
		}
		nfcInitializer();
		nfcListener();
	}
	if (kind == 'usb' || !kind) {
		navigator.usb.requestDevice({ filters: [] }).then(function(devices) { console.log(devices); });
	}

}


function numericals() {
	numerics = "";
	if ($('#ticket').is(':visible')) {
		numerics = "";
		$('#ticket').find('.ticket_input').each(function() {
			numerics = numerics + $(this).val();
		});
	}
	return numerics;
}

$(document).on('click', '#password_clear', function() {
	$('#credential_insert').val('');
	$('#ticket').find('.ticket_input').each(function() {
		$(this).val('');
	});
});

$(document).on('click','.delete_backup', function() {
	var a = $(this);
	var timestamp = Date.now();
	var filename = a.attr('filename');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		if (filename) {
			$.ajax({
				url: '/manager/configure/delete_backup',
				type: 'POST',
				data: { timestamp: timestamp, filename: filename },
				success:function(response) {
					if (response == 'backup deleted') {
						a.closest('.backup').remove();
					}
				}
			});
		}
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

$(document).on('change', '.pos, .mab', function(e) {
	var d = $(this);
	var setting = d.attr('setting');
	var parent = d.closest('.appointment_configuration_cell');
	var display = parent.find('.appointment_display');
	var a = d.attr('app');
	var o = e.currentTarget.selectedOptions[0];
	o = $(o).val();
	var now = Date.now();
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { timestamp: now, app: a, setting: setting, value: o },
		success: function(response) { display.html(response); }
	});
});
$(document).on('change', '.configure_checkbox', function(e) {
	var d = $(this);
	var parent = d.closest('.appointment_configuration_cell');
	var display = parent.find('.appointment_display');
	var a = d.attr('app');
	var now = Date.now();
	var setting = d.attr('setting');
	if (d.is(':checked')) { value = "checked"; } else { value = "unchecked"; }
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: a, timestamp: timestamp, setting: setting, value: value },
		success: function(response) { 
			display.html(response); 
			localStorage.removeItem('manager_search_cache');
		}
	});
});
$(document).on('change', '.configure_visibility', function(e) {
	var s = $(this);
	var parent = s.closest('.appointment_configuration_cell');
	var display = parent.find('.appointment_display');
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: s.attr('app'), timestamp: Date.now(), setting: 'visible', value: s.val() },
		success: function(response) {
			display.html(response);
			localStorage.removeItem('manager_search_cache');
		}
	});
});
$(document).on('change', '.map_key_input', function() {
	// Configure -> Plat -> Maps: the tile-service keys are house settings, not an
	// appointment setting, so they go through the plain setter and say so.
	var input = $(this);
	var status = $('#map_keys_status');
	status.text('saving…');
	settingSetter({ app: input.attr('app') || '__president', setting: input.attr('setting'), value: input.val() }).then(function() {
		status.text('saved');
		setTimeout(function() { if (status.text() == 'saved') { status.text(''); } }, 2500);
	});
});

$(document).on('change', '.movement_device_input', function() {
	// Configure -> Plat -> Maps -> Movement: which device files an appointment's
	// movement. A house setting like the tile keys, so it reaches every machine —
	// it is written as device 'all' because that is how it is read.
	var input = $(this);
	var status = $('#movement_device_status');
	status.text('saving…');
	settingSetter({ app: input.attr('app') || '__president', setting: input.attr('setting'), device: 'all', value: input.val() }).then(function() {
		status.text('saved');
		setTimeout(function() { if (status.text() == 'saved') { status.text(''); } }, 2500);
	});
});

$(document).on('change', '.configure_input', function(e) {
	var e = $(this);
	url = '/manager/configure';
	var setting = e.attr('setting');
	var app = e.attr('app');
	var button = $('.app_configure_toggle[setting="' + setting + '"][app="' + app + '"]');
	var value = e.val();
	if (e.attr('type') == 'checkbox') {
		value = e.prop('checked') ? 'on' : 'off';
	}
	var parent = e.closest('.appointment_configuration_cell');
	var display = parent.find('.appointment_display');
	var timestamp = Date.now();
	if (e.attr('multiple')) {
		value = JSON.stringify(value);
	}
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: app, timestamp: timestamp, setting: setting, value: value },
		success: function(response) {
			// a rename into a name the house already knows answers with a conflict,
			// not with a display: the panel asks which value keeps the name. This is
			// also the only path a phone takes - its keyboard has no Enter, just a
			// Next that blurs the field, so the change event is what fires there
			if (response && response.conflict) { nameConflictPanel(response); return; }
			display.html(response);
			localStorage.removeItem('manager_search_cache');
			// the theme select lives in the app's head, not in an ability panel
			if (setting != 'theme') {
				button.find('.ability_label').html('<b>' + button.attr('formatted_setting') + ':</b> ' + value.slice(0,20));
				configurationGrabber({ app: app, setting: [setting] });
			}
		}
	});
});

// The sync topology is a house setting, not a per-window preference: the Dev
// panel's select writes the shared `device: 'all'` row, the settings merge carries
// it to the other machines, and the reconnector reads it on each pass. It posts
// to the JSON setter rather than /manager/configure, which would answer with an
// appointment display for an app that has none.
$(document).on('change', '.sync_topology_select', function() {
	var status = $('#sync_topology_status');
	status.text('saving…');
	$.ajax({
		url: '/manager/setting_setter',
		type: 'POST',
		data: { app: 'sync', setting: 'topology', value: $(this).val(), device: 'all', timestamp: Date.now() },
		success: function() { status.text('house-wide — saved'); },
		error: function() { status.text('could not save'); }
	});
});

// The update method is the same kind of house setting: which authority the
// auto-update watcher follows (none, GitHub, peers, or either). It is read by
// the boot-time watcher on each pass, so a save takes effect on the next tick.
$(document).on('change', '.update_method_select', function() {
	var status = $('#update_method_status');
	var t = function(s) { return (typeof jawnosT === 'function') ? jawnosT(s) : s; };
	status.text(t('saving…'));
	$.ajax({
		url: '/manager/setting_setter',
		type: 'POST',
		data: { app: 'sync', setting: 'update_method', value: $(this).val(), device: 'all', timestamp: Date.now() },
		success: function() { status.text(t('house-wide — saved')); },
		error: function() { status.text(t('could not save')); }
	});
});

// The coding nightly pushes to the repo named here, not blindly to origin. The
// server validates owner/name or an https URL (no spaces, no credentials) and
// answers with the effective target, which is what the line under the fields
// shows. Empty is the checkout's own remote: origin, or fork for the app.
$(document).on('change', '.coding_push_repo_input, .coding_app_push_repo_input', function() {
	var input = $(this);
	var app = input.hasClass('coding_app_push_repo_input');
	var field = app ? 'app_repo' : 'repo';
	var status = app ? $('#coding_app_push_repo_status') : $('#coding_push_repo_status');
	var effective = app ? $('#coding_app_push_repo_effective') : $('#coding_push_repo_effective');
	var t = function(s) { return (typeof jawnosT === 'function') ? jawnosT(s) : s; };
	status.text(t('saving…'));
	$.post('/manager/configure/coding_push_repo', { field: field, value: input.val() }, function(res) {
		if (!res || !res.ok) {
			status.text((res && res.error) || t('could not save'));
			return;
		}
		input.val(res.value || '');
		effective.text(res.effective || '');
		status.text(t('house-wide — saved'));
	}).fail(function() {
		status.text(t('could not save'));
	});
});

// Paint the version the bar carries. The update route hands back the number it
// read after the pull, so the top bar changes the moment an update lands.
function jawnosConfigureVersion(version) {
	if (!version) { return; }
	$('#configure .jawn_version').text('v' + String(version).replace(/^v/i, ''));
}

// The manual update button. It uses the selected method's source, so a machine
// left on Manual - GitHub or Manual - Peers can be updated without turning the
// watcher back on. A dirty tree or local commits are reported first; either
// force path discards what blocks the pull only after a confirmation.
