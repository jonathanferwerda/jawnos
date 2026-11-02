
// A panel opening or closing is an event, not a layout. The beat used to report
// it the expensive way: every act toggle changed the whole window_saver blob, so
// the next beat re-sent every window's position, size and open panels, and the
// server wrote a jopen for every window on the way through. This is the narrow
// road instead - one small frame per open/close, naming the one window that
// changed, sent the moment it changes. The beat keeps the geometry.
var appActPosted = {};

function appActSync(target) {
	var win = (typeof target === 'string') ? $('.wind[app="' + target + '"]') : target;
	if (!win || !win.length) { return; }
	var app = win.attr('app');
	if (!app) { return; }
	var state;
	try { state = windowjOpenSaver(win); } catch (e) { return; }
	var json = JSON.stringify(state);
	// a re-rendered window is a new window: its own state is news even when it
	// matches what the window it replaced was showing
	var key = app + '@' + (win.attr('timestamp') || '');
	if (appActPosted[key] == json) { return; }
	appActPosted[key] = json;
	// the tab socket is the one that speaks for the page as a whole
	var socket = (typeof ws === 'object' && ws) ? ws['tab'] : null;
	if (!socket || socket.readyState != 1) { return; }
	try {
		socket.send(JSON.stringify({ type: 'act', app: 'tab', window: app, jopen: json }));
	}
	catch (e) { delete appActPosted[key]; }
}
