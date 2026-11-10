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
		var id = $(this).attr('id');
		jawnosConfirm('Remove this passkey from the house?', function () {
			$.post('/manager/webauthn/remove', { id: id }, function (r) {
				if (!r || !r.ok) { alert((r && r.error) || 'could not remove'); return; }
				securityRefresh();
			}, 'json');
		});
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

	$(document).on('click', '#lockdown_unlock', function () {
		var b = $(this);
		var note = $('#lockdown_unlock_note');
		b.prop('disabled', true);
		note.css('color', 'darkred').text(typeof jawnosT === 'function' ? jawnosT('Touch the fingerprint reader…') : 'Touch the fingerprint reader…');
		$.post('/manager/security/lockdown_unlock', { timestamp: Date.now() }, function (r) {
			b.prop('disabled', false);
			if (!r || !r.ok) {
				note.css('color', 'darkred').text((r && r.error) || 'could not unlock');
				return;
			}
			note.css('color', '#2f6f3f').text(typeof jawnosT === 'function' ? jawnosT('Unlocked. Open the appointment and stop it; the lockdown ends with it.') : 'Unlocked. Open the appointment and stop it; the lockdown ends with it.');
			if (typeof calculator === 'function') { calculator(); }
		}, 'json').fail(function () {
			b.prop('disabled', false);
			note.css('color', 'darkred').text('could not unlock');
		});
	});

	// The lockdown names the hidden appointment; this opens it. The route is the
	// same fingerprint reveal, and a grant already minted (Security itself was
	// just opened) lets it through without a second prompt.
	$(document).on('click', '.lockdown_open_app', function () {
		var b = $(this);
		var app = b.attr('data-app') || '';
		if (!app) { return; }
		var note = $('#lockdown_unlock_note');
		b.prop('disabled', true);
		$.post('/manager/security/lockdown_unlock', { timestamp: Date.now() }, function (r) {
			b.prop('disabled', false);
			if (!r || !r.ok) {
				note.css('color', 'darkred').text((r && r.error) || 'could not unlock');
				return;
			}
			note.css('color', '#2f6f3f').text(typeof jawnosT === 'function' ? jawnosT('Unlocked. Opening the appointment; stopping it ends the lockdown.') : 'Unlocked. Opening the appointment; stopping it ends the lockdown.');
			if (typeof appointmentGrabber === 'function') { appointmentGrabber(app, Date.now()); }
		}, 'json').fail(function () {
			b.prop('disabled', false);
			note.css('color', 'darkred').text('could not unlock');
		});
	});

	var guarded = /^\/manager\/security\/(lockdown_unlock|rotate_key|legacy_reseal|recovery\/create|shares\/create|shares\/wrap|shares\/release)/;
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
