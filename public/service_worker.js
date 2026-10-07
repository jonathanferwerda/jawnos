
// The app only needs a service worker to be installable as a PWA (Chrome on
// Android), so this is a pure pass-through. Requests that a re-issued fetch
// can harm are deliberately left to the browser instead of being intercepted:
// uploads and form posts, range requests (scrubbing media), and the encrypted
// file store behind /file_open.
self.addEventListener('install', (event) => {
	self.skipWaiting();
});

self.addEventListener('activate', (event) => {
	event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', (event) => {
	const request = event.request;
	let url;
	try { url = new URL(request.url); } catch (e) { return; }
	if (request.method !== 'GET') { return; }
	if (url.origin !== self.location.origin) { return; }
	if (request.headers.get('range')) { return; }
	if (url.pathname.indexOf('/file_open') === 0) { return; }
	// navigations are all that the installability check needs, and they are the
	// one request that is safe to re-issue; everything else (scripts, styles,
	// images) is left to the browser so the ?string= asset versioning behaves
	// exactly as it does without a service worker
	if (request.mode === 'navigate') {
		event.respondWith(fetch(request));
	}
});
