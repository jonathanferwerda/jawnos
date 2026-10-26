// ---- artwork, fetched together ----------------------------------------------
// A music library and a photo grid ask for one picture per card. Asking
// /file_open once per picture made a burst the browser was happy to start but
// the manager was not built to answer: a phone resting two prefork workers had
// none left as soon as a few covers arrived, and every other route queued behind
// them. This collects the pictures the screen is about to show into one request
// (/manager/thumbs), hands each <img> its data URI, and only falls back to a
// single /file_open - at two at a time - for the few the batch could not answer
// (a missing thumb, or a file kept on another machine).
//
// New markup asks for this with data-artwork="<file_open url>" (or data-src,
// which the gallery's own lazy observer already uses). Nothing here needs the
// app to know: any visible img with one of those attributes is picked up.

(function () {
	if (window.jawnosArtwork) { return; }

	var PLACEHOLDER = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
	var BATCH_MAX = 40;       // one request is one worker; keep it a screenful
	var DIRECT_MAX = 2;       // leave a worker free even on a two-worker phone
	var RETRY_MAX = 3;        // a generated thumb answers with a 1x1 placeholder
	var RETRY_DELAY = 2500;

	var pending = [];         // { img, url } waiting for the next batch
	var direct = [];          // direct loads waiting for a free slot
	var batched = false;
	var active = 0;
	var timer = null;
	var observer = null;
	var scanTimer = null;

	function pump() {
		while (active < DIRECT_MAX && direct.length) {
			var item = direct.shift();
			if (!item.img || !item.img.isConnected) { continue; }
			active++;
			request(item);
		}
	}

	function request(item) {
		var img = item.img;
		var done = false;
		var guard = null;
		function finish() {
			if (done) { return; }
			done = true;
			if (guard) { clearTimeout(guard); }
			img.onload = null;
			img.onerror = null;
			active--;
			pump();
		}
		img.onload = function () {
			if (!this.isConnected) { finish(); return; }
			// A thumb that is still being generated answers with the 1x1
			// placeholder. Ask again in a moment rather than leaving it blank.
			if (this.naturalWidth <= 1 && (item.tries || 0) < RETRY_MAX) {
				item.tries = (item.tries || 0) + 1;
				var url = item.url + (item.url.indexOf('?') >= 0 ? '&' : '?') + 'retry=' + item.tries;
				setTimeout(function () {
					if (!done && img.isConnected) { img.src = url; }
				}, RETRY_DELAY * item.tries);
				return;
			}
			finish();
		};
		img.onerror = function () { finish(); };
		// A picture on a machine that is asleep may never answer; do not hold one
		// of the few direct slots for ever.
		guard = setTimeout(finish, 25000);
		img.src = item.url;
	}

	function queueDirect(item) {
		direct.push(item);
		pump();
	}

	function take(img, url) {
		if (!img || !url) { return; }
		if (!img.getAttribute('src')) { img.src = PLACEHOLDER; }
		pending.push({ img: img, url: url });
		if (pending.length >= BATCH_MAX) { flush(); return; }
		if (!timer) { timer = setTimeout(flush, 30); }
	}

	function flush() {
		timer = null;
		if (batched || !pending.length) { return; }
		var batch = pending.splice(0, BATCH_MAX);
		// Tracks in one album share a cover: send each address once and hand the
		// same answer to every card that asked for it.
		var urls = [];
		var slots = {};
		var wanted = [];
		for (var i = 0; i < batch.length; i++) {
			var url = batch[i].url;
			if (!(url in slots)) { slots[url] = urls.length; urls.push(url); }
			wanted.push({ item: batch[i], slot: slots[url] });
		}
		batched = true;
		$.ajax({
			url: '/manager/thumbs',
			type: 'POST',
			contentType: 'application/json',
			dataType: 'json',
			data: JSON.stringify({ urls: urls }),
			success: function (response) {
				var items = (response && response.items) || {};
				for (var n = 0; n < wanted.length; n++) {
					var item = wanted[n].item;
					if (!item.img || !item.img.isConnected) { continue; }
					var src = items[wanted[n].slot];
					if (src) { item.img.src = src; }
					else { queueDirect(item); }
				}
			},
			error: function () {
				// An older manager has no bundle route, or the session lapsed.
				// Every picture still has its own working address.
				for (var n = 0; n < batch.length; n++) { queueDirect(batch[n]); }
			},
			complete: function () {
				batched = false;
				if (pending.length) { flush(); }
			}
		});
	}

	function start(img) {
		var url = img.getAttribute('data-artwork');
		if (!url) { return; }
		img.removeAttribute('data-artwork');
		take(img, url);
	}

	function scan() {
		var held = document.querySelectorAll('img[data-artwork]');
		if (!held.length) { return; }
		if (!('IntersectionObserver' in window)) {
			Array.prototype.forEach.call(held, start);
			return;
		}
		if (!observer) {
			observer = new IntersectionObserver(function (entries) {
				entries.forEach(function (entry) {
					if (!entry.isIntersecting) { return; }
					observer.unobserve(entry.target);
					start(entry.target);
				});
			}, { root: null, rootMargin: '300px' });
		}
		Array.prototype.forEach.call(held, function (img) { observer.observe(img); });
	}

	function queueScan() {
		if (scanTimer) { return; }
		scanTimer = setTimeout(function () { scanTimer = null; scan(); }, 120);
	}

	window.jawnosArtwork = {
		placeholder: PLACEHOLDER,
		scan: scan,
		// A caller that already decided the picture is visible (the gallery's
		// own observer) can hand it over here without a second observation.
		load: function (img, url) {
			if (!img) { return; }
			var src = url || img.getAttribute('data-src') || img.getAttribute('data-artwork');
			if (!src) { return; }
			img.removeAttribute('data-src');
			img.removeAttribute('data-artwork');
			take(img, src);
		}
	};

	$(document).ready(function () {
		scan();
		if (window.MutationObserver) {
			new MutationObserver(queueScan).observe(document.body, { childList: true, subtree: true });
		}
	});
})();
