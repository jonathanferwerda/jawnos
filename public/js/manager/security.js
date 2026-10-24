

// The paper-share QR images come back as data URIs and are also saved under
// ~/.jawnos_paper_shares/<stamp>/ on this machine. The page shows them once.
function jawnosShareQr(target, dirTarget, qr) {
	var $t = $(target).empty();
	var $d = $(dirTarget).empty();
	if (!qr || !qr.images || !qr.images.length) { return; }
	var share = (typeof jawnosT === 'function') ? jawnosT('Share') : 'Share';
	qr.images.forEach(function (img) {
		var box = $('<div>').css({ display: 'inline-block', textAlign: 'center', margin: '6px' });
		$('<img>').attr({ src: img.data, alt: share + ' ' + img.index, title: share + ' ' + img.index })
			.css({ width: '160px', height: '160px' }).appendTo(box);
		$('<div>').text(share + ' ' + img.index).css({ fontSize: '12px' }).appendTo(box);
		box.appendTo($t);
	});
	var saved = (typeof jawnosT === 'function') ? jawnosT('Saved in') : 'Saved in';
	$d.text(saved + ' ' + qr.dir + (qr.missing ? ' (' + qr.missing + ' not made)' : ''));
}

$(document).on('click', '#security_toggle', function() {

	var url = '/manager/security';

	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response.html)
		}, error: function (response) { 
		}
	});
});

$(document).on('click', '#padlock_gate_enable, #padlock_gate_disable', function() {
	var button = $(this);
	var url = (button.attr('id') == 'padlock_gate_enable')
		? '/manager/security/gate/enable'
		: '/manager/security/gate/disable';
	button.prop('disabled', true);
	$.ajax({
		url: url,
		type: 'POST',
		data: { timestamp: Date.now() },
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				$('#padlock_set_status').text(response && response.error ? response.error : 'The gate did not change.');
				return;
			}
			$('#security').replaceWith(response.html);
			appointment_chron();
			// the taskbar padlock is rendered with the layout, so enabling the
			// gate used to leave it hidden until a refresh; the reply carries
			// the new state and the same broadcast reaches other screens
			if (typeof response.has_padlock !== 'undefined') {
				$('#lock_session').toggle(!!response.has_padlock);
			}
		},
		error: function() {
			button.prop('disabled', false);
			$('#padlock_set_status').text('The gate did not change.');
		}
	});
});

$(document).on('change', '#padlock_contexts', function() {
	var contexts = $(this).val();
	contexts = JSON.stringify(contexts); 
	settingSetter({ 'app': '__president', 'setting': 'padlock_contexts', 'value': contexts });
});

$(document).on('change', '#padlock_gate', function() {
	settingSetter({ 'app': '__president', 'setting': 'padlock_gate', 'value': $(this).val() });
});

// Off / shadow / enforce for the app-only manager gate. Shadow is the safe way
// to see what a browser would lose before it is turned on for real.
$(document).on('change', '#app_access', function() {
	settingSetter({ 'app': '__president', 'setting': 'app_access', 'device': 'all', 'value': $(this).val() });
});

// The phone's own biometric unlock: the Android app makes a Keystore key that
// the OS releases only after the fingerprint prompt, and registers its public
// half here. The locked page can also enroll on the spot. An already-enrolled
// fingerprint must pass before a new one can replace it.
$(document).on('click', '#padlock_biometric_enroll_button', function() {
	var button = $(this);
	var status = $('#padlock_biometric_status');
	if (typeof jawnosBiometricEnroll !== 'function') {
		status.text('Fingerprint unlock is not available in this app.');
		return;
	}
	var enrolled = (button.attr('data-enrolled') === '1');
	button.prop('disabled', true);
	var confirmed = enrolled
		? jawnosBiometricVerify(function (text) { status.text(text); })
		: Promise.resolve(null);
	confirmed.then(function (proof) {
		return jawnosBiometricEnroll(function (text) { status.text(text); }, proof);
	}).then(function() {
		button.prop('disabled', false);
		button.attr('data-enrolled', '1');
		button.text("Replace this phone's fingerprint");
		status.text(enrolled
			? 'Replaced. This phone unlocks with the new fingerprint.'
			: 'Enrolled. This phone can unlock its own screen with your fingerprint.');
	}).catch(function(err) {
		button.prop('disabled', false);
		status.text((typeof jawnosBiometricError === 'function') ? jawnosBiometricError(err) : 'Fingerprint enrollment failed.');
	});
});


$(document).on('click', '.security_view_select', function() {
	var view = $(this).attr('view');
	settingSetter({
		'app': '__president',
		'setting': 'security_view',
		'value': view
	});
	$('.security_view').hide();
	$('.security_view[view="' + view + '"]').show();
	$('.security_view_select').css({ 'background-color': 'lightgray' });
	$('.security_view_select[view="' + view +'"]').css({ 'background-color': 'lightgreen' });


	var url = '/manager/security';

	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { timestamp: timestamp, security_view: view },
		success: function(response) {
			$('#security').replaceWith(response.html);
			appointment_chron();
		}, error: function (response) { 
		}
	});
});

$(document).on('click', '.neighbour_link_updater', function() {
	var nlu = $(this);
	var nl = nlu.closest('.neighbour_link');
	var uuid = nl.attr('uuid');
	var nlus = $('.neighbour_link_updater_selection[uuid="' + uuid + '"]');
	if (nlus.is(':visible')) {
		nlus.hide();
	}
	else {
		nlus.show();
	}
});

$(document).on('click', '.neighbour_link_privilege_change', function() {
	var privilege = $(this).attr('privilege');
	var nl = $(this).closest('.neighbour_link_updater_selection');
	var uuid = nl.attr('uuid');
	$.ajax({
		url: '/manager/security/neighbour_link_privilege',
		type: 'POST',
		data: { uuid: uuid, privilege: privilege },
		success: function(response) {
			$('#security').html(response);
			appointment_chron();
		}
	});
});


$(document).on('click', '.neighbour_link_credential', function() {
	var nlr = $(this).closest('.neighbour_link_request');
	var privilege = $(this).attr('privilege');
	var credential = nlr.attr('credential');
	var remote_address = nlr.attr('remote_address');
	var local_address = nlr.attr('local_address');
	var my_name = nlr.attr('my_name');
	$.ajax({
		url: '/manager/security/neighbour_link_assign',
		type: 'POST',
		data: {
			privilege: privilege,
			remote_address: remote_address,
			local_address: local_address,
			my_name: my_name,
			credential: credential
		},
		success: function(response) {
			jawnosAlertClose();
		}
	});
});

$(document).on('click', '.neighbour_link_delete', function() {
	var uuid = $(this).closest('.neighbour_link').attr('uuid');
	$.ajax({
		url: '/manager/security/neighbour_link_delete',
		type: 'POST',
		data: { uuid: uuid },
		success: function(response) {
			$('#security').html(response);
			appointment_chron();
		}
	});
});

$(document).on('click', '.device_revoke', function() {
	var uuid = $(this).closest('.paired_device').attr('uuid');
	$.ajax({
		url: '/manager/security/device_revoke',
		type: 'POST',
		data: { uuid: uuid },
		success: function(response) {
			$('#security').replaceWith(response.html);
			appointment_chron();
		}
	});
});

// Who a device belongs to. The device in the hand may not be demoted below
// citizen: the live session keeps its privilege until the next login, and that
// login would read the lower one.
$(document).on('change', '.device_person_select', function() {
	var select = $(this);
	$.ajax({
		url: '/manager/security/person_assign',
		type: 'POST',
		data: { device_uuid: select.attr('device'), person_uuid: select.val() || '', security_view: 'devices' },
		success: function(response) {
			if (response && response.html) {
				$('#security').replaceWith(response.html);
				appointment_chron();
			}
			else {
				jawnosAlert(response && response.error ? response.error : 'Could not assign that person');
			}
		},
		error: function() {
			jawnosAlert('Could not assign that person');
		}
	});
});

$(document).on('click', '#person_add_button', function() {
	var name = ($('#person_new_name').val() || '').trim();
	if (!name) { jawnosAlert('Type a name first'); return; }
	$.ajax({
		url: '/manager/security/person_create',
		type: 'POST',
		data: { name: name, privilege: $('#person_new_privilege').val() || 'resident', security_view: 'devices' },
		success: function(response) {
			if (response && response.html) {
				$('#security').replaceWith(response.html);
				appointment_chron();
			}
			else {
				jawnosAlert('Could not add that person');
			}
		},
		error: function() {
			jawnosAlert('Could not add that person');
		}
	});
});

$(document).on('click', '.person_revoke', function() {
	var button = $(this);
	var row = button.closest('.person_row');
	var uuid = row.attr('uuid');
	var original = button.text();
	if (button.attr('armed') !== 'yes') {
		button.attr('armed', 'yes');
		button.css({ 'background-color': 'red' });
		button.text(typeof jawnosT === 'function' ? jawnosT('Press again') : 'Press again');
		setTimeout(function() {
			button.attr('armed', 'no');
			button.css({ 'background-color': '' });
			button.text(original);
		}, 3000);
		return;
	}
	button.attr('armed', 'no');
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/security/person_revoke',
		type: 'POST',
		data: { person_uuid: uuid, security_view: 'devices' },
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				jawnosAlert(response && response.error ? response.error : 'Could not revoke that person');
				button.text(original);
				return;
			}
			$('#security').replaceWith(response.html);
			appointment_chron();
		},
		error: function() {
			button.prop('disabled', false);
			button.text(original);
			jawnosAlert('Could not revoke that person');
		}
	});
});

$(document).on('click', '#recovery_create', function() {
	$.ajax({
		url: '/manager/security/recovery/create',
		type: 'POST',
		data: { timestamp: Date.now(), security_view: 'recovery' },
		success: function(response) {
			if (!response || !response.ok || !response.code) {
				jawnosAlert('Could not make a recovery code');
				return;
			}
			$('#security').replaceWith(response.html);
			appointment_chron();
			$('#recovery_code_display').show();
			$('#recovery_code_value').text(response.code);
		},
		error: function() {
			jawnosAlert('Could not make a recovery code');
		}
	});
});

$(document).on('click', '#shares_create', function() {
	$.ajax({
		url: '/manager/security/shares/create',
		type: 'POST',
		data: { security_view: 'recovery' },
		success: function(response) {
			if (!response || !response.ok || !response.shares) {
				jawnosAlert('Could not make the shares');
				return;
			}
			$('#security').replaceWith(response.html);
			appointment_chron();
			$('#shares_display').show();
			$('#shares_value').text((response.shares || []).join('\n'));
			jawnosShareQr('#shares_qr', '#shares_qr_dir', response.qr);
		},
		error: function() {
			jawnosAlert('Could not make the shares');
		}
	});
});

$(document).on('click', '.device_request_decide', function() {
	var row = $(this).closest('.device_request');
	var uuid = row.attr('uuid');
	var decision = $(this).attr('decision');
	$.ajax({
		url: '/manager/security/device_request_decide',
		type: 'POST',
		data: { uuid: uuid, decision: decision },
		success: function(response) {
			if (response && response.html) {
				$('#security').replaceWith(response.html);
				appointment_chron();
			}
		}
	});
});

$(document).on('change', '#vault_share_tick', function() {
	settingSetter({ 'app': '__president', 'setting': 'vault_share', 'value': ($(this).is(':checked') ? 'yes' : 'no') });
});

$(document).on('click', '#rotate_key', function() {
	var button = $(this);
	if (button.attr('armed') != 'yes') {
		button.attr('armed', 'yes');
		button.css({ 'background-color': 'red' });
		$('#rotate_key_note').text('Press again to rotate: sessions restart and the recovery code is set aside.');
		setTimeout(function() {
			button.css({ 'background-color': '' });
			button.attr('armed', 'no');
		}, 3000);
		return;
	}
	button.attr('armed', 'no');
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/security/rotate_key',
		type: 'POST',
		data: { timestamp: Date.now() },
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				$('#rotate_key_note').text('Rotation did not run.');
				return;
			}
			$('#security').replaceWith(response.html);
			appointment_chron();
			$('#rotate_key_note').text('Rotated. Write down a new recovery code. Sealed files re-seal in the background, and linked machines are handed the new key.');
		},
		error: function() {
			button.prop('disabled', false);
			$('#rotate_key_note').text('Rotation did not run.');
		}
	});
});

$(document).on('click', '#legacy_reseal', function() {
	var button = $(this);
	button.prop('disabled', true);
	$('#legacy_reseal_note').text('Upgrading...');
	$.ajax({
		url: '/manager/security/legacy_reseal',
		type: 'POST',
		data: { timestamp: Date.now() },
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				$('#legacy_reseal_note').text('The upgrade did not run.');
				return;
			}
			var local = response.local || {};
			var mesh = response.mesh || {};
			var here = (local.settings || 0) + (local.security || 0) + (local.links || 0);
			$('#legacy_reseal_note').text('Upgraded here: ' + here + '. On linked machines: ' + (mesh.upgraded || 0) + ' (' + (mesh.ok || 0) + ' of ' + (mesh.asked || 0) + ' answered' + ((mesh.failed || 0) ? ', ' + mesh.failed + ' not answering yet' : '') + ').');
		},
		error: function() {
			button.prop('disabled', false);
			$('#legacy_reseal_note').text('The upgrade did not run.');
		}
	});
});

$(document).on('click', '.signatorial_selection', function() {
	var sig = $(this);
	var file = sig.attr('file');
	$.ajax({
		url: '/manager/security/signatorial/selection',
		type: 'POST',
		data: { file: file },
		success: function(response) {
			$('#security').replaceWith(response.html);
		}
	});



});
// --- device-held shares -------------------------------------------------------
// A device makes one X25519 key for shares and keeps it non-extractable. The
// server wraps a share to its public half; the device unwraps only when a
// recovering machine asks, and re-seals the share to that machine's ephemeral
// key. See docs/house-key-roles-and-shamir.md.
(function () {
	function idb() {
		return new Promise(function (res, rej) {
			var r = indexedDB.open('jawn_share', 1);
			r.onupgradeneeded = function () { r.result.createObjectStore('keys'); };
			r.onsuccess = function () { res(r.result); };
			r.onerror = function () { rej(r.error); };
		});
	}
	function idbGet(k) {
		return idb().then(function (db) {
			return new Promise(function (res, rej) {
				var q = db.transaction('keys', 'readonly').objectStore('keys').get(k);
				q.onsuccess = function () { res(q.result); };
				q.onerror = function () { rej(q.error); };
			});
		});
	}
	function idbPut(k, v) {
		return idb().then(function (db) {
			return new Promise(function (res, rej) {
				var tx = db.transaction('keys', 'readwrite');
				tx.objectStore('keys').put(v, k);
				tx.oncomplete = function () { res(); };
				tx.onerror = function () { rej(tx.error); };
			});
		});
	}

	// Make (or load) this device's share key and tell the house its public half.
	// The key is non-extractable; only the public half ever leaves the device.
	function ensureShareKey() {
		var S = window.jawnosShareCrypto;
		if (!S || !S.supported()) { return Promise.reject(new Error('no x25519')); }
		return idbGet('share_key').then(function (key) {
			if (key) {
				return Promise.all([idbGet('share_pub'), idbGet('share_spki')]).then(function (a) {
					var pub = a[0];
					var spki = a[1];
					if (pub && spki) { return { key: key, pub: pub, spki: S.unb64(spki) }; }
					// an old key with no recorded public half cannot be used for the
					// key derivation; replace it rather than fail every release
					return S.generate().then(function (pair) {
						return Promise.all([S.publicRaw(pair.publicKey), S.publicSpki(pair.publicKey)]).then(function (b) {
							var p = S.b64(b[0]);
							return idbPut('share_key', pair.privateKey)
								.then(function () { return idbPut('share_pub', p); })
								.then(function () { return idbPut('share_spki', S.b64(b[1])); })
								.then(function () { return { key: pair.privateKey, pub: p, spki: b[1], fresh: true }; });
						});
					});
				});
			}
			return S.generate().then(function (pair) {
				return Promise.all([S.publicRaw(pair.publicKey), S.publicSpki(pair.publicKey)]).then(function (a) {
					var pub = S.b64(a[0]);
					var spki = a[1];
					return idbPut('share_key', pair.privateKey)
						.then(function () { return idbPut('share_pub', pub); })
						.then(function () { return idbPut('share_spki', S.b64(spki)); })
						.then(function () { return { key: pair.privateKey, pub: pub, spki: spki, fresh: true }; });
				});
			});
		}).then(function (got) {
			return $.post('/manager/security/shares/key', { share_pubkey: got.pub }).then(function (r) {
				got.registered = !!(r && r.ok);
				return got;
			}, function () { return got; });
		});
	}

	$(document).on('click', '#shares_wrap', function () {
		var button = $(this);
		var holders = $('.share_device:checked').map(function () { return $(this).attr('device'); }).get().join(',');
		button.prop('disabled', true);
		// register this device's share key first, so an unlisted device can still
		// take a share when nothing is ticked (the server picks one per person)
		ensureShareKey().catch(function () {}).then(function () {
			$.ajax({
				url: '/manager/security/shares/wrap',
				type: 'POST',
				data: { holders: holders, security_view: 'recovery' },
				success: function (r) {
					button.prop('disabled', false);
					if (!r || !r.ok) { jawnosAlert('Could not make device shares'); return; }
					$('#security').replaceWith(r.html);
					appointment_chron();
					$('#shares_wrap_display').show();
					var paper = r.paper || [];
					$('#shares_wrap_value').text(paper.join('\n'));
					var held = (r.assigned || []).map(function (a) {
						return '#' + a.share_index + ' — ' + (a.device_name || a.device);
					});
					$('#shares_wrap_assigned').text(held.length
						? 'Held by: ' + held.join(', ') + (paper.length ? '' : '. Every share is on a device — nothing to write down.')
						: 'No device took a share.');
					$('#shares_wrap_display p b').text(paper.length ? 'Write these down now — they will not be shown again.' : 'All shares are held by devices — nothing to write down.');
					jawnosShareQr('#shares_wrap_qr', '#shares_wrap_qr_dir', r.qr);
				},
				error: function () {
					button.prop('disabled', false);
					jawnosAlert('Could not make device shares');
				}
			});
		});
	});

	// Release one share to the machine that asked: unwrap it with this device's
	// key, seal it to the asker's ephemeral key, and hand over the opaque blob.
	$(document).on('click', '.share_release', function () {
		var button = $(this);
		var row = button.closest('.share_request');
		var request_uuid = row.attr('uuid');
		var asker = row.attr('asker');
		var note = $('#share_release_note');
		button.prop('disabled', true);
		note.css('color', 'darkred').text('');
		ensureShareKey().then(function (got) {
			return $.post('/manager/security/shares/mine', { set_id: row.attr('set_id') || '' }).then(function (r) {
				if (!r || !r.ok || !r.shares || !r.shares.length) { throw new Error('no share'); }
				var mine = r.shares[0];
				return window.jawnosShareCrypto.unwrap(mine.wrapped, got.key, got.spki).then(function (raw) {
					return window.jawnosShareCrypto.wrap(raw, asker).then(function (blob) {
						return $.post('/manager/security/shares/release', {
							request_uuid: request_uuid,
							share_index: mine.share_index,
							wrapped: blob
						});
					});
				});
			});
		}).then(function (r) {
			button.prop('disabled', false);
			if (r && r.ok) {
				note.css('color', 'green').text('Released. The asking machine has this share now.');
			}
			else {
				note.text((r && r.error) ? r.error : 'Could not release it.');
			}
		}).catch(function (e) {
			button.prop('disabled', false);
			note.text((e && e.message === 'no share')
				? 'This device holds no share in the current set.'
				: 'Could not release it.');
		});
	});

	$(document).on('click', '#share_requests_refresh', function () {
		$.ajax({
			url: '/manager/security',
			type: 'GET',
			data: { security_view: 'recovery', window_maker: 'yes' },
			success: function (r) {
				if (r && r.html) {
					$('#security').replaceWith(r.html);
					appointment_chron();
				}
			}
		});
	});

	// register quietly when the Recovery view is opened, so this device can take
	// a share the next time a set is made
	$(document).on('click', '.security_view_select[view="recovery"], #security_toggle', function () {
		ensureShareKey().catch(function () {});
	});
})();

// ---- passkeys (WebAuthn) ---------------------------------------------------
// Registration is the only place a credential is made. The public half is what
// the house keeps; the private half never leaves the platform authenticator.
(function () {
	function b64uToBytes(s) {
		s = String(s || '').replace(/-/g, '+').replace(/_/g, '/');
		var pad = s.length % 4;
		if (pad) { s += '='.repeat(4 - pad); }
		var bin = atob(s);
		var out = new Uint8Array(bin.length);
		for (var i = 0; i < bin.length; i++) { out[i] = bin.charCodeAt(i); }
		return out;
	}
	function bytesToB64u(buf) {
		var b = new Uint8Array(buf), s = '';
		for (var i = 0; i < b.length; i++) { s += String.fromCharCode(b[i]); }
		return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
	}
	function securityRefresh() {
		$.ajax({
			url: '/manager/security',
			type: 'GET',
			data: { security_view: 'passkeys', window_maker: 'yes', unlock: (window.jawnosSecurityToken || ''), browser_tab_id: (typeof jawnosMediaTab === 'function' ? jawnosMediaTab() : '') },
			success: function (r) {
				if (r && r.html) {
					$('#security').replaceWith(r.html);
					if (typeof appointment_chron === 'function') { appointment_chron(); }
				}
			}
		});
	}
	// the app's own door (below) redraws through this after an unlock
	window.jawnosSecurityRefresh = securityRefresh;

	$(document).on('click', '#passkey_add', function () {
		var status = $('#passkey_status');
		if (!window.PublicKeyCredential || !navigator.credentials) {
			status.text('this browser has no passkey support (or the page is not on https)');
			return;
		}
		// A passkey is bound to the house domain, so the page has to be open on
		// it. On 127.0.0.1 the browser refuses before it ever prompts, so say
		// that here rather than let it surface as a cryptic SecurityError.
		var rp = String($(this).attr('data-rp') || '').toLowerCase();
		var host = String(window.location.hostname || '').toLowerCase();
		var on_house = rp.length > 0 && (host === rp || host.slice(-(rp.length + 1)) === ('.' + rp));
		if (!on_house) {
			status.text('this window is on ' + (host || 'an address') + ', not ' + (rp || 'the house domain') + ' - press Open in browser to enroll on the house name');
			return;
		}
		status.text('asking the house…');
		$.post('/manager/webauthn/register/begin', {}, function (r) {
			if (!r || !r.ok) { status.text((r && r.error) || 'could not start'); return; }
			var pk = r.publicKey;
			navigator.credentials.create({ publicKey: {
				challenge: b64uToBytes(pk.challenge),
				rp: pk.rp,
				user: { id: b64uToBytes(pk.user.id), name: pk.user.name, displayName: pk.user.displayName },
				pubKeyCredParams: pk.pubKeyCredParams,
				timeout: pk.timeout,
				attestation: pk.attestation,
				authenticatorSelection: pk.authenticatorSelection,
				excludeCredentials: (pk.excludeCredentials || []).map(function (c) {
					return { type: c.type, id: b64uToBytes(c.id), transports: c.transports };
				})
			} }).then(function (cred) {
				if (!cred) { throw new Error('no credential'); }
				$.post('/manager/webauthn/register/finish', {
					client_data: bytesToB64u(cred.response.clientDataJSON),
					attestation: bytesToB64u(cred.response.attestationObject),
					transports: (cred.response.getTransports ? cred.response.getTransports().join(',') : ''),
					name: $('#passkey_name').val() || 'Passkey'
				}, function (f) {
					if (!f || !f.ok) { status.text((f && f.error) || 'could not save'); return; }
					securityRefresh();
				}, 'json');
			}).catch(function (e) {
				var name = (e && e.name) || '';
				var msg = (e && e.message) || 'cancelled';
				status.text(name ? (name + ': ' + msg) : msg);
			});
		}, 'json');
	});

	$(document).on('click', '.passkey_remove', function () {
		if (!confirm('Remove this passkey from the house?')) { return; }
		$.post('/manager/webauthn/remove', { id: $(this).attr('id') }, function (r) {
			if (!r || !r.ok) { alert((r && r.error) || 'could not remove'); return; }
			securityRefresh();
		}, 'json');
	});

	// The app window is on 127.0.0.1, which is not a usable WebAuthn origin. Mint
	// a short, single-use link and hand it to a real browser on the house name.
	$(document).on('click', '#passkey_open_browser', function () {
		var status = $('#passkey_status');
		status.text('making a one-time link…');
		$.post('/manager/webauthn/enroll_link', {}, function (r) {
			if (!r || !r.ok) { status.text((r && r.error) || 'could not make a link'); return; }
			var w = window.open(r.url, '_blank');
			if (!w) {
				status.html('Popup blocked - open this link in a browser: <a href="' + r.url + '" target="_blank" rel="noopener">' + r.url + '</a>');
			}
			else {
				status.text('opened in a browser - finish there');
			}
		}, 'json');
	});
})();

// ---- Security's own door ---------------------------------------------------
// This app holds the ways the house can be opened, so it opens locked, and the
// actions that change the key ask again with a grant no older than two minutes.
// The server answers those with need_biometric; this asks the phone and replays
// the very same request with the fresh grant, so no call site has to know.
(function () {
	var token = '';
	var pending = null;

	function askStatus() {
		var s = $('.security_unlock_status').first();
		if (!s.length) {
			s = $('<div class="security_confirm_status" style="position:fixed;left:50%;transform:translateX(-50%);bottom:26px;background:#222;color:#fff;padding:10px 16px;border-radius:10px;font-size:14px;z-index:99999;"></div>').appendTo('body');
		}
		return s;
	}

	window.jawnosSecurityGrant = function (grant) {
		token = String(grant || '');
		window.jawnosSecurityToken = token;
		$('.security_unlock_status').text('Unlocked.');
		var f = pending; pending = null;
		if (typeof f === 'function') { f(token); }
	};

	function redraw() {
		if (typeof window.jawnosSecurityRefresh === 'function') { window.jawnosSecurityRefresh(); }
	}

	// This device's own reader first; otherwise the phone in the house confirms
	// this screen, and the grant comes back over the socket.
	function localReader() {
		var d = $.Deferred();
		var tab = (typeof jawnosMediaTab === 'function' ? jawnosMediaTab() : '');
		$.post('/manager/security/fingerprint_unlock', { mode: 'security', browser_tab_id: tab }, function (r) {
			if (!r || !r.pending || !r.token) { d.reject(r || { error: 'no reader' }); return; }
			var tries = 0;
			(function poll() {
				if (tries++ > 18) { d.reject({ error: 'timeout' }); return; }
				$.get('/manager/security/fingerprint_unlock_status', { token: r.token, browser_tab_id: tab }, function (s) {
					if (s && s.pending) { setTimeout(poll, 1200); return; }
					if (s && s.ok && s.unlock) { d.resolve(String(s.unlock)); return; }
					d.reject(s || { error: 'not accepted' });
				}, 'json').fail(function () { d.reject({ error: 'reader error' }); });
			})();
		}, 'json').fail(function () { d.reject({ error: 'no reader' }); });
		return d.promise();
	}

	function askPhone(st, then) {
		pending = then;
		st.text('Confirm on your phone…');
		$.post('/manager/security/padlock_phone_show', {
			mode: 'security', target: jawnDeviceUuid(), browser_tab_id: jawnosMediaTab()
		}, function (r) {
			if (!r || !r.ok) { pending = null; st.text('The house did not ask your phone.'); }
		}, 'json');
	}

	function confirmWith(then) {
		var st = askStatus();
		if (window.JawnBiometricKey && typeof jawnosBiometricUnlock === 'function') {
			st.text('Waiting for your fingerprint…');
			jawnosBiometricUnlock('security', jawnDeviceUuid(), function (t) { st.text(t); }, null, false, '', '').then(function (r) {
				if (r && r.unlock) { st.text(''); window.jawnosSecurityGrant(r.unlock); then(String(r.unlock)); }
				else { st.text('Not confirmed.'); }
			}, function (e) {
				st.text(typeof jawnosBiometricError === 'function' ? jawnosBiometricError(e) : 'Not confirmed.');
			});
			return;
		}
		st.text('Touch the fingerprint reader…');
		localReader().then(function (grant) {
			st.text('');
			window.jawnosSecurityGrant(grant);
			then(grant);
		}, function (e) {
			// no reader here, or it was busy: the phone is the other way in
			if (e && e.error && e.error !== 'no fingerprint' && e.error !== 'local only' && e.error !== 'busy' && e.error !== 'no reader' && e.error !== 'timeout' && e.error !== 'no result' && e.error !== 'reader error' && e.error !== 'no device') {
				st.text('The reader did not accept that print.');
				return;
			}
			askPhone(st, then);
		});
	}

	$(document).on('click', '.security_unlock', function () {
		confirmWith(function (grant) {
			window.jawnosSecurityToken = grant;
			redraw();
		});
	});

	$(document).on('click', '.security_code_go', function () {
		var st = $('.security_code_status');
		var code = $('.security_code').val() || '';
		if (!code.replace(/\s+/g, '')) { st.text('Type the code first.'); return; }
		st.text('Checking…');
		$.post('/manager/security/confirm_code', { code: code, browser_tab_id: jawnosMediaTab() }, function (r) {
			if (!r || !r.ok || !r.unlock) {
				st.text((r && r.error === 'too many') ? 'Too many tries. Wait an hour.' : 'That code was not accepted.');
				return;
			}
			st.text('');
			window.jawnosSecurityGrant(r.unlock);
			redraw();
		}, 'json');
	});

	var guarded = /^\/manager\/security\/(rotate_key|legacy_reseal|recovery\/create|shares\/create|shares\/wrap|shares\/release)/;
	var guarded_key = /^\/manager\/webauthn\/(register\/begin|register\/finish|remove)/;
	$(document).ajaxSuccess(function (event, xhr, settings) {
		var r = xhr.responseJSON || {};
		if (!r.need_biometric || settings.security_retried) { return; }
		var url = settings.url || '';
		if (!guarded.test(url) && !guarded_key.test(url)) { return; }
		confirmWith(function (grant) {
			var tab = (typeof jawnosMediaTab === 'function' ? jawnosMediaTab() : '');
			var body;
			if (typeof settings.data === 'string') {
				body = settings.data + '&unlock=' + encodeURIComponent(grant) + (tab ? '&browser_tab_id=' + encodeURIComponent(tab) : '');
			}
			else {
				body = $.extend({}, settings.data || {}, { unlock: grant, browser_tab_id: tab });
			}
			$.ajax({
				url: url, type: settings.type || 'POST', data: body, dataType: 'json',
				security_retried: 1,
				success: settings.success, error: settings.error, complete: settings.complete
			});
		});
	});
})();
