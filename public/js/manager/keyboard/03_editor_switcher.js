function debrief_setter() {
	$('#timeshift_viewer').html($('#timeshift').val() + $('#timeshift_scope').val());
}


$(document).on('mousemove', function(m) {
	mouse = m;
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
});

$(document).on('mousemove', '#pseudonym_home', function(m) {
	mouse = m;
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
	pseudonymHomeShower(x,y);
});

function textareaUpgrader() {
	$('textarea[upgradeable="yes"]').each(function(i,v) {
		if ($(v).attr('upgraded') != 'yes') {
			var ta = $(v);
			var id = ta.attr('id');

			if (ta.attr('id') == undefined || ta.attr('id') == '') {
				id = Math.random().toString(36).substring(2);
				ta.attr('id', id);
			}
			var classList = [];
			$.each(ta[0].classList, function(ic,vc) {
				classList.push(vc);
			});
			var attributes = {};
			$.each(ta[0].attributes, function(ic, vc) {
				attributes[vc.name] = vc.value;
			});

			var placeholder = ta.attr('placeholder');
			var contents = ta.val();
			// A textarea's rows make its height; a contenteditable div has no rows,
			// so keep the height the person was already looking at. Without this the
			// note field collapsed when the editor replaced it.
			// A drawer upgraded before it is shown measures zero, so rows and the
			// textarea's own line box are the fallback.
			var ta_height = ta.outerHeight();
			if (!(ta_height > 0)) {
				var rows = parseInt(ta.attr('rows'), 10);
				if (rows > 0) {
					var line = parseFloat(ta.css('line-height'));
					if (!(line > 0)) { line = (parseFloat(ta.css('font-size')) || 15) * 1.4; }
					ta_height = rows * line
						+ (parseFloat(ta.css('padding-top')) || 0)
						+ (parseFloat(ta.css('padding-bottom')) || 0)
						+ (parseFloat(ta.css('border-top-width')) || 0)
						+ (parseFloat(ta.css('border-bottom-width')) || 0);
				}
			}
			// Claim the field before the request leaves. The answer is async, and a
			// second pass (a restore that draws the window twice) would otherwise
			// start a second editor for the same textarea, so the note appeared
			// more than once. A request that fails gives the claim back.
			ta.attr('upgraded', 'yes');
			$.ajax({
				url: '/manager/text_editor/create',
				type: 'GET',
				data: { id: id, contents: contents, placeholder: placeholder, magic_vars: ta.attr('magic_vars') || '' },
				error: function() { ta.removeAttr('upgraded'); },
				success: function(response) {
					var p_id = response.p_id;
					id = response.id;
					ta.attr('upgraded', 'yes');
					var $prepender = $(response.html);
					ta.before($prepender);
					$.each(classList, function(io, vo) {
						ta.removeClass(vo);
						$('#' + p_id).addClass(vo);
					});
					$.each(attributes, function(io, vo) {
						if (io != 'id' && io != 'class') {

							$('#' + p_id).attr(io, vo);
						}
					});
					if (ta_height > 0) {
						$('#' + p_id).css('min-height', ta_height + 'px');
					}
					// The container is not a scroll box: its heights are all auto, so the
					// overflow only ever clipped. The variable legend lives in the toolbox
					// now and opens upward from there, and nothing may cut it at the edge.
					$prepender.css({ 'overflow':'visible' });
					$(document).on('change', '#' + id, function() {

						var te = textEditorProcessor($('#' + id));
						$('#' + p_id).html(te);
					});
					$(document).on('keyup', '#' + p_id, function(e) {
						var box = $('#' + p_id);
						$('#' + id).val(box.text());
						if (e.keyCode != 186) { return; }
						// ${vape}->duration; names the variable outright, so it is eaten
						// without the wand; anything else waits to be asked for
						var word = (box.text().match(/(\S+);$/) || [])[1] || '';
						var named = /\$\{[^}\s]+\}->[A-Za-z0-9_]+$/.test(word) || /\$[A-Za-z_][A-Za-z0-9_]*->[A-Za-z0-9_]+$/.test(word);
						textEditorMagic(box, named);
					});

					ta.hide();
					// the editor exists now; a draft from another device can fill it
					if (typeof jawnosAppDraftHydrate === 'function') { jawnosAppDraftHydrate(ta.attr('app')); }
				}
			});
		}
	});
}

// The toolbox is shown once the editor is being used, not on hover: a toolbar
// that appears under a moving pointer is a button pressed by accident.
$(document).on('focus click', '.text_editor_container', function(e) {
	var source_id = $(this).attr('source_id');
	$('.text_editor_toolbox[source_id="' + source_id + '"]').show();
});

// A click on the padding or the toolbox row is a click meant for the text.
$(document).on('click', '.text_editor_container', function(e) {
	if ($(e.target).closest('.text_editor_toolbox').length == 0 && !$(e.target).closest('.text_editor').length) {
		$(this).find('.text_editor').focus();
	}
});

$(document).on('blur', '.text_editor_container', function(e) {
	if (!$(e.target).closest('.text_editor_container')) {
		var source_id = $(this).attr('source_id');
		$('.text_editor_toolbox[source_id="' + source_id + '"]').hide();
	}
});

$(document).on('click', '.teb_style', function() {
	var ts = $(this);
	var tb = ts.closest('.text_editor_toolbox');
	var id = tb.attr('t_id');
	var ta = $('#' + id);
	var tag = ts.attr('tag');
	var status = ts.attr('status');
	if (status == 'on') {
		status = 'off';
		if (tag) {
			ta.html(ta.html() + '</' + tag + '>');
		}
	} else {
		status = 'on';
		$(this).attr('status', status);
		if (tag) {
			ta.html(ta.html() + '<' + tag + '>');
		}
		if (ts.attr('utility') == 'magic_wand') {
			textEditorMagic(ta);
		}
	}
	ta.focus();
	$(this).attr('status', status);
});

function textEditorMagic(dom, force) {
	var text = dom.html();
	var id = dom.attr('id');
	var container = dom.closest('.text_editor_container');
	var toolbox = container.find('.text_editor_toolbox');
	var wand = toolbox.find('.teb_style[utility="magic_wand"]');
	var source_id = dom.attr('source_id');
	if (wand.attr('status') == 'on' || force) {

		// magic_vars says what ${self} is about here - the appointment the editor
		// sits in, or the quote/invoice and customer the compose was opened for
		var data = { method: 'textAreaMagic', text: text, id: id, source_id: source_id, magic_vars: dom.attr('magic_vars') || '' };

		var jdata = JSON.stringify(data);

		ws['tab'].send(jdata);
	}

}

$(document).on('click', '.text_editor_illusion', function() {
	var tei = $(this);
	var original = tei.attr('original');
	var trick = tei.attr('trick');
	var displaying = tei.attr('displaying');
	if (displaying == 'original') {
		tei.text(trick);
		tei.attr('displaying', 'trick');
	} else {
		tei.text(original);
		tei.attr('displaying', 'original');
	}
});

function textEditorProcessor(text) {

	text = text.replace(/\r\n|\r|\n/g, '<br>');
	if (text == '<br>') {
		text = '';
	}
	return text;
}


// Marker (paint board) shortcuts, kept here with the rest of the key
// handling. Returns true when the key was used, so the keyboard app leaves it
// alone.
function markerShortcut(e) {
	if (typeof markerUndo != 'function') { return false; }
	if ($('#whiteboard').length == 0 || !$('#whiteboard').is(':visible')) { return false; }
	if ($(e.target).is('input, textarea, select, [contenteditable], .text-editor')) { return false; }
	var key = (e.key || '').toLowerCase();
	if (e.ctrlKey || e.metaKey) {
		if (e.altKey) { return false; }
		if (key == 'z') {
			if (e.shiftKey) { markerRedoStep(); } else { markerUndo(); }
			e.preventDefault();
			return true;
		}
		if (key == 'y') { markerRedoStep(); e.preventDefault(); return true; }
		return false;
	}
	// the plain keys only act while the board is the window in front
	var marker_app = $('#whiteboard').closest('.wind').attr('app') || 'marker';
	if (topWindow() != marker_app) { return false; }
	if (key == '+' || key == '=') { markerZoomCentre(1.25); e.preventDefault(); return true; }
	if (key == '-' || key == '_') { markerZoomCentre(1 / 1.25); e.preventDefault(); return true; }
	if (key == '0') { markerViewFit(); e.preventDefault(); return true; }
	return false;
}

$(document).on('keydown', function(e) {
	var timestamp = Date.now();
	keysPressed[jawnosKeyCode(e)] = { key: e.key, timestamp: timestamp };
	var app = topWindow();
	var dialog = topDialog();
	var win = $('.wind[app="' + app + '"]');

	var movInc = 5;
	if (markerShortcut(e)) { return; }
	if (e.keyCode == 13) {
		if ($('.dialog_box').length > 0) {
			e.preventDefault();
			var d = $($('.dialog_box')[$('.dialog_box').length - 1]);
			d.find('.ok').trigger('click');
			console.log('dialog box showing');
		}
		if (app == 'folders') {
			e.preventDefault();
			if ($(e.target).not('input')) {
				foldersFileOpener()
			}
		}
	}
	else if (e.keyCode == 27) {
		var dialog_cancelled = false;
		if ($('.dialog_box').length > 0) {
			e.preventDefault();
			var d = $($('.dialog_box')[$('.dialog_box').length - 1]);
			d.find('.cancel').trigger('click');
			dialog_cancelled = true;
		}
		if (!dialog_cancelled) {
			// Escape leaves a fullscreen picture. The browser's own handling
			// never runs here: the Music window's shortcut block calls
			// preventDefault for every key, so the page has to leave fullscreen
			// itself. An open dialog still takes the first Escape.
			var fs = document.fullscreenElement || document.webkitFullscreenElement;
			if (fs) {
				e.preventDefault();
				var out = document.exitFullscreen ? document.exitFullscreen()
					: (document.webkitExitFullscreen ? document.webkitExitFullscreen() : null);
				if (out && out.catch) { out.catch(function () {}); }
			}
		}
	}
	else if (e.keyCode == 65 && e.ctrlKey == true) {
		if (topWindow() == 'folders') {
			
			e.preventDefault();
			foldersCommand({ command: 'select_all' });
		}
	}
	else if (e.keyCode == 18 && e.ctrlKey == true) {
		startMenuToggle();
	} else if (e.keyCode == 37 && keysPressed[91]) { //left

		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				// the window may hang up to half off the side, but the titlebar
				// buttons (top right) have to stay reachable
				var minLeft = -Math.min(win.width() / 2, win.width() - 95);
				var l = numeral(win.css('left')).value() - movInc;
				if (l > minLeft) {
					win.css({ 'left': l });
				}
			}
		}
		else {
			if ($('#app_switcher').is(':visible')) {
				appSwitcher('subtract');
			} else {
				var app = topWindow();
				var win = $('.wind[app="' + app + '"]');
				windowHalfski(win,'left');
			}
		}
	} else if (e.keyCode == 39 && keysPressed[91]) { //right
		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				// pushed right the buttons leave the screen first, so a right push
				// stops with the window's right edge still on screen: all three
				// stay visible and clickable
				var maxLeft = $(window).width() - win.width();
				var l = numeral(win.css('left')).value() + movInc;
				if (l < maxLeft) {
					win.css({ 'left': l });
				}
			}
		}
		else {
			if ($('#app_switcher').is(':visible')) {
				appSwitcher();
			} else {
				var app = topWindow();
				var win = $('.wind[app="' + app + '"]');
				windowHalfski(win,'right');
			}
		}
	} else if (e.keyCode == 38 && keysPressed[91]) { //up
		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				// a strip of the titlebar (and its buttons) stays on screen
				var l = numeral(win.css('top')).value() - movInc;
				if (l > -18) {
					win.css({ 'top': l });
				}
			}
		}
		else {
			var app = topWindow();
			var win = $('.wind[app="' + app + '"]');
			var timestamp = win.attr('timestamp');
			if (win.attr('view') == 'max') {
				windowRestore(timestamp,app);
			} else {
				windowMaximizer(timestamp, app);
			}
		}
	} else if (e.keyCode == 40 && keysPressed[91]) { //down
		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				var topNavbarHeight = numeral(win.find('.top_navbar').css('height')).value();
				var l = numeral(win.css('top')).value() + movInc;
				if (l < $(window).height() - topNavbarHeight) {
					win.css({ 'top': l });
				}
			}
		}
		else {
			var app = topWindow();
			var win = $('.wind[app="' + app + '"]');
			var timestamp = win.attr('timestamp');
			windowMinimizer(timestamp, app);
			topLevelNow($('.wind[app="' + topWindow() + '"]'));
		}
	} else if (e.keyCode == 81 && keysPressed[91]) { //Q
		var app = topWindow();
		var win = $('.wind[app="' + app + '"]');
		var timestamp = win.attr('timestamp');
		closeWindow(timestamp);
	} else if (e.keyCode == 16 && keysPressed[91]) {
		appSwitcher();
	} else if (!$(e.target).is('input') && !$(e.target).is('textarea') && !$(e.target).is('select') && !$(e.target).hasClass('.text_editor') && e.ctrlKey == false && topWindow() == 'music') {
			e.preventDefault();
			if (e.keyCode == 32 && !keysPressed[91]) {
				console.log('space bar');
				$('#play').trigger('click');
			}
			if (e.keyCode == 37 && !keysPressed[91]) {
				$('#prev').trigger('click');
			}
			if (e.keyCode == 38 && !keysPressed[91]) {
				$('.next_chapter').trigger('click');
			}
			if (e.keyCode == 39 && !keysPressed[91]) {
				$('#next').trigger('click');
			}
			if (e.keyCode == 40 && !keysPressed[91]) {
				$('.last_chapter').trigger('click');
			}
			if (e.keyCode == 70 && !keysPressed[91]) {
				// music.js owns the target: an audio track has no picture, so the
				// whole player goes fullscreen (the visualisation rides along)
				if (typeof musicPlayerFullscreen == 'function') { musicPlayerFullscreen(); }
				else { tree.sound.requestFullscreen(); }
			}
		}


/*
	if (e.keyCode == 83 && e.ctrlKey == true && e.altKey == true) { // ctrl+alt+s
		configureToggle();
	}
	if (e.keyCode == 77 && e.ctrlKey == true && e.altKey == true) { // ctrl+alt+m
		musicToggle();
	}
*/
});

$(document).on('keyup', function(e) {
	var jawnos_code = jawnosKeyCode(e);
	delete keysPressed[jawnos_code];
	if (jawnos_code == 91) {
		appSwitcher('chose');
	}
});

function appSwitcher(duty) {
	var as = $('#app_switcher');
	as.find('.app').css({ 'border':'none', 'background-color': 'transparent' });
	if (duty == 'chose') {
		if (as.is(':visible')) {
			as.hide();
			var s = $(as.find('.app')[appSwitcherSelected]);
			var app = s.find('.window_toggle_name').attr('app');
			topLevelNow($('.wind[app="' + app + '"]'));
			$('.wind[app="' + app + '"]').show();
			appSwitcherSelected = 0;
		}
	}
	else {
		if (!as.is(':visible')) {
			startMenuDisplayer('#app_switcher');
		}
		var count = as.find('.app').length;
		if (duty == 'subtract') {
			appSwitcherSelected--;
			if (appSwitcherSelected < 0) {
				appSwitcherSelected = count - 1;
			}
		} else {
			appSwitcherSelected++;
			if (appSwitcherSelected >= count) {
				appSwitcherSelected = 0;
			}
		}
		$(as.find('.app')[appSwitcherSelected]).css({ 'border':'solid', 'border-width': '5px', 'background-color': 'yellow', 'border-radius': '5%' });
		as.css({'display': 'flex' }).show();
	}
}

// The remote_control panel's command box: tell the selected machine what to do.
// The command is sent as plain words and read by that machine's own guide, so it
// stays on that machine; the reply is what it reports back.
function jawnosRemoteCommand() {
	var uuid = $('#remote_control_machine_select').val();
	var text = $.trim($('#remote_command_text').val() || '');
	var reply = $('#remote_command_reply');
	if (!uuid) { reply.text('Pick a machine other than Me first.'); return; }
	if (!text) { return; }
	reply.text('Sending...');
	$.post('/manager/remote_command/send', { remote_uuid: uuid, text: text }, function (r) {
		reply.text((r && (r.observation || r.error)) || 'no reply');
	}).fail(function () { reply.text('no reply'); });
}

// The remote_control panel's VPN button: set this device's tailnet exit node,
// so its web traffic leaves at that machine's address. The node is not
// necessarily a machine this house has enrolled - the house's own server
// usually is not a roster row, and a roster row carries no tailnet address
// unless the peer reported one - so the list comes from the tailnet itself
// (/manager/tailnet/status) rather than from the machine picker above.
// Android answers through the JawnVPN bridge (the embedded client owns the
// VPN); a Linux peer asks its own manager, which drives the local tailscale.
function jawnosVpnSelected() {
	var opt = $('#remote_control_machine_select').find('option:selected');
	return { uuid: opt.val() || '', ip: opt.attr('data-tailnet') || '' };
}

// The peers that can carry this device's traffic: online, and offering an exit
// node. An offline node is left out because picking it would only show a
// button that cannot connect.
function jawnosVpnNodes(status) {
	var nodes = [];
	var peers = (status && status.peers) || [];
	for (var i = 0; i < peers.length; i++) {
		var p = peers[i] || {};
		if (!p.ip || !p.exit || !p.online) { continue; }
		nodes.push({ ip: p.ip, name: p.name || p.ip });
	}
	return nodes;
}

function jawnosVpnStatus(cb) {
	if (window.JawnVPN && typeof window.JawnVPN.status === 'function') {
		try { cb(JSON.parse(window.JawnVPN.status())); return; } catch (e) {}
	}
	$.getJSON('/manager/tailnet/status', function (s) { cb(s || {}); })
		.fail(function () { cb({ available: 0, exit: '', peers: [] }); });
}

// Keep the exit-node list in step with the tailnet, and keep the choice: the
// machine picked above if it is itself an exit node, then the node already
// carrying the traffic, then what was chosen before, then the first one.
function jawnosVpnChooser(nodes, preferred) {
	var sel = $('#remote_control_vpn_node');
	if (!sel.length) { return ''; }
	var before = sel.val() || '';
	var have = {};
	sel.empty();
	for (var i = 0; i < nodes.length; i++) {
		have[nodes[i].ip] = 1;
		sel.append($('<option>').val(nodes[i].ip).text(nodes[i].name));
	}
	var want = '';
	var wanted = (preferred || []).concat([before]);
	for (var j = 0; j < wanted.length; j++) {
		var ip = wanted[j] || '';
		if (ip && have[ip]) { want = ip; break; }
	}
	if (!want && nodes.length) { want = nodes[0].ip; }
	sel.val(want);
	$('#remote_control_vpn_row').toggle(nodes.length > 0);
	return want;
}

function jawnosVpnTarget() {
	return $('#remote_control_vpn_node').val() || '';
}

function jawnosVpnPaint(on) {
	var b = $('#remote_control_vpn');
	if (!b.length) { return; }
	var target = jawnosVpnTarget();
	b.attr('status', on ? 'on' : 'off');
	b.prop('disabled', !on && !target);
	b.css({
		'opacity': (on || target) ? 1 : 0.45,
		'background-color': on ? 'var(--jawnos-ok, #4caf50)' : ''
	});
	b.attr('hint', on ? jawnosT('Turn the VPN off') : jawnosT("Route this device's web traffic through the exit node chosen beside it"));
}

function jawnosVpnRefresh() {
	var b = $('#remote_control_vpn');
	if (!b.length) { return; }
	// The VPN moves this device's own traffic, so it belongs to the Me view;
	// a peer view has no exit-node list and shows no button.
	if (!$('#remote_control_vpn_node').length) { b.hide(); return; }
	jawnosVpnStatus(function (s) {
		var nodes = jawnosVpnNodes(s);
		var picked = jawnosVpnSelected();
		var on = !!(s && s.exit);
		jawnosVpnChooser(nodes, [picked.ip, (s && s.exit) || '']);
		b.show();
		jawnosVpnPaint(on);
		if (!on && !nodes.length) {
			b.attr('hint', jawnosT('No machine on the tailnet offers an exit node'));
		}
	});
}

// The Me view's public address. With a VPN exit node in force it is that
// machine's address; without one it is this device's ISP address, so the line is
// the quickest check that the VPN is really carrying the traffic.
function jawnosPublicIpPaint(ip) {
	var el = $('#local_public_ip');
	if (!el.length) { return; }
	if (ip) {
		el.text(ip).css('opacity', 1);
	}
	else {
		el.text(jawnosT('not known')).css('opacity', .65);
	}
}

function jawnosPublicIpRefresh(refresh) {
	if (!$('#local_public_ip').length) { return; }
	$('#local_public_ip_row').show();
	$('#local_public_ip').text(jawnosT('checking…')).css('opacity', .65);
	$.getJSON('/manager/public_ip' + (refresh ? '?refresh=1' : ''), function (r) {
		if (r && r.disabled) { $('#local_public_ip_row').hide(); return; }
		jawnosPublicIpPaint((r && r.ip) || '');
	}).fail(function () { jawnosPublicIpPaint(''); });
}

function jawnosVpnToggle() {
	var b = $('#remote_control_vpn');
	if (!b.length) { return; }
	var on = b.attr('status') === 'on';
	var target = on ? '' : jawnosVpnTarget();
	if (!on && !target) { return; }
	b.prop('disabled', true);
	var finish = function (r) {
		b.prop('disabled', false);
		if (!r || r.ok === false || r.ok === 0) {
			b.attr('hint', (r && r.error) || jawnosT('The VPN could not be changed'));
			return;
		}
		jawnosVpnRefresh();
		// The route can take a moment to appear in the tailnet status, so ask
		// again rather than leaving the button reading "off" after a success.
		setTimeout(jawnosVpnRefresh, 1200);
		// The public address is the proof the route actually moved, so look it up
		// again after the change settles instead of leaving the old ISP answer.
		if (typeof jawnosPublicIpRefresh == 'function') {
			$('#local_public_ip').text(jawnosT('checking…'));
			setTimeout(function () { jawnosPublicIpRefresh(true); }, 1500);
		}
	};
	if (window.JawnVPN && typeof window.JawnVPN.setExitNode === 'function') {
		try { finish(JSON.parse(window.JawnVPN.setExitNode(target))); return; } catch (e) { finish({ ok: false, error: '' + e }); return; }
	}
	$.post('/manager/tailnet/exit', { ip: target }, finish, 'json').fail(function () { finish({ ok: false }); });
}
$(document).on('click', '#remote_command_send', function () { jawnosRemoteCommand(); });
$(document).on('click', '#remote_control_vpn', function () { jawnosVpnToggle(); });
// While the Me view is open, keep the public address fresh: the VPN can also be
// switched from the desktop or another window, not only by this panel's button.
setInterval(function () {
	if ($('#local_public_ip').length && $('#local_public_ip').is(':visible')) { jawnosPublicIpRefresh(); }
}, 60000);
