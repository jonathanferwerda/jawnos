// --- device shares -----------------------------------------------------------
// The same construction house_key_wrap uses in Perl: X25519 agreement, SHA-256
// over both public halves and a context, AES-256-GCM. A device generates one
// X25519 key for shares (its login key may be Ed25519, which cannot agree) and
// keeps it non-extractable. Nothing here is secret on the wire: the wrapped
// blob is useless without the device key, and a release is re-sealed to the
// asking machine's ephemeral key.
window.jawnosShareCrypto = (function () {
	var CONTEXT = 'jawnos/house-key/v1';
	var enc = new TextEncoder();
	var ctx = enc.encode(CONTEXT);

	function toU8(x) {
		if (x instanceof Uint8Array) { return x; }
		if (x && x.buffer instanceof ArrayBuffer) { return new Uint8Array(x.buffer, x.byteOffset || 0, x.byteLength); }
		return new Uint8Array(x);
	}
	function cat(parts) {
		var total = 0;
		parts.forEach(function (p) { total += (typeof p === 'string') ? enc.encode(p).length : toU8(p).length; });
		var out = new Uint8Array(total);
		var off = 0;
		parts.forEach(function (p) {
			var a = (typeof p === 'string') ? enc.encode(p) : toU8(p);
			out.set(a, off);
			off += a.length;
		});
		return out;
	}
	function b64(bytes) {
		var a = toU8(bytes);
		var s = '';
		for (var i = 0; i < a.length; i++) { s += String.fromCharCode(a[i]); }
		return btoa(s);
	}
	function unb64(s) {
		var bin = atob(String(s || '').replace(/\s+/g, ''));
		var a = new Uint8Array(bin.length);
		for (var i = 0; i < bin.length; i++) { a[i] = bin.charCodeAt(i); }
		return a;
	}
	function supported() {
		return !!(window.crypto && crypto.subtle && crypto.subtle.generateKey && crypto.subtle.importKey && window.TextEncoder);
	}
	function generate() {
		return crypto.subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']);
	}
	function publicRaw(key) {
		return crypto.subtle.exportKey('raw', key).then(function (b) { return new Uint8Array(b); });
	}
	function publicSpki(key) {
		return crypto.subtle.exportKey('spki', key).then(function (b) { return new Uint8Array(b); });
	}
	function aesKey(shared, ephSpki, recipientSpki) {
		var material = cat([ctx, [0], shared, [0], ephSpki, [0], recipientSpki]);
		return crypto.subtle.digest('SHA-256', material).then(function (hash) {
			return crypto.subtle.importKey('raw', hash, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
		});
	}
	// open a house_key_wrap blob with this device's private key
	function unwrap(blobB64, privateKey, ownPublicSpki) {
		var blob = unb64(blobB64);
		if (blob.length < 5 + 1 + 2 + 12 + 16) { return Promise.reject(new Error('short blob')); }
		if (String.fromCharCode.apply(null, blob.slice(0, 5)) !== 'JHKY1') { return Promise.reject(new Error('not a key blob')); }
		if (blob[5] !== 1) { return Promise.reject(new Error('not X25519')); }
		var len = (blob[6] << 8) | blob[7];
		if (blob.length < 8 + len + 12 + 16) { return Promise.reject(new Error('short blob')); }
		var ephSpki = blob.slice(8, 8 + len);
		var iv = blob.slice(8 + len, 8 + len + 12);
		var tag = blob.slice(8 + len + 12, 8 + len + 28);
		var ct = blob.slice(8 + len + 28);
		return crypto.subtle.importKey('spki', ephSpki, { name: 'X25519' }, false, [])
			.then(function (ephKey) {
				return crypto.subtle.deriveBits({ name: 'X25519', public: ephKey }, privateKey, 256)
					.then(function (shared) { return aesKey(new Uint8Array(shared), ephSpki, ownPublicSpki); });
			})
			.then(function (key) {
				return crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv, additionalData: ctx, tagLength: 128 }, key, cat([ct, tag]));
			})
			.then(function (plain) { return new Uint8Array(plain); });
	}
	// seal bytes to a recipient's raw X25519 public key
	function wrap(bytes, recipientRawB64) {
		var recipientRaw = unb64(recipientRawB64);
		return generate().then(function (pair) {
			return Promise.all([publicSpki(pair.publicKey),
				crypto.subtle.importKey('raw', recipientRaw, { name: 'X25519' }, true, [])])
				.then(function (a) { return [pair, a[0], a[1]]; });
		}).then(function (a) {
			var pair = a[0], ephSpki = a[1], recipientKey = a[2];
			return publicSpki(recipientKey).then(function (recipientSpki) {
				return crypto.subtle.deriveBits({ name: 'X25519', public: recipientKey }, pair.privateKey, 256)
					.then(function (shared) { return aesKey(new Uint8Array(shared), ephSpki, recipientSpki); })
					.then(function (key) {
						var iv = crypto.getRandomValues(new Uint8Array(12));
						return crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv, additionalData: ctx, tagLength: 128 }, key, toU8(bytes))
							.then(function (ctTag) {
								var all = new Uint8Array(ctTag);
								var ct = all.slice(0, all.length - 16);
								var tag = all.slice(all.length - 16);
								var out = cat(['JHKY1', [1],
									[Math.floor(ephSpki.length / 256), ephSpki.length % 256],
									ephSpki, iv, tag, ct]);
								return b64(out);
							});
					});
			});
		});
	}
	return { supported: supported, generate: generate, publicRaw: publicRaw, publicSpki: publicSpki, unwrap: unwrap, wrap: wrap, b64: b64, unb64: unb64 };
})();

// The manager can be opened in shadow mode, where the app-required page never
// runs and the session never learns this install's app key. Prove it on every
// load: app-only actions (a peer Go ticket) need app_device on the session.
(function () {
	var busy = false;
	function signIn() { jawnAppLogin(true).catch(function () {}); }
	function prove() {
		if (!window.JawnDesktop) { return; }
		if (typeof jawnAppLogin !== 'function' || typeof jawnDeviceUuid !== 'function') { return; }
		var uuid = jawnDeviceUuid();
		if (uuid) { signIn(); return; }
		if (busy) { return; }
		// A cleared or restored WebKit profile can lose the stored device id
		// while the app key is still the one paired with the house. Name the
		// device by its key, keep the id, then sign in.
		if (typeof jawnosDesktopCall !== 'function' || typeof jawnDeviceUuidSave !== 'function') { return; }
		busy = true;
		jawnosDesktopCall('app_pubkey', {}).then(function (res) {
			if (!res || !res.pubkey) { throw { error: 'no key' }; }
			return $.post('/manager/device/app_identify', { app_pubkey: res.pubkey });
		}).then(function (r) {
			if (r && r.ok && r.uuid) {
				jawnDeviceUuidSave(r.uuid);
				signIn();
			}
		}).catch(function () {}).then(function () { busy = false; });
	}
	// The manager page can keep loading long after it is usable (previews,
	// media), so do not wait only for `load`: prove at DOM ready and once more
	// shortly after, with a debounce inside prove().
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', function () { setTimeout(prove, 500); });
	}
	window.addEventListener('load', function () { setTimeout(prove, 500); });
	setTimeout(prove, 1500);
})();
