// A browser game records play the way the Gou's emulated games do: one Games
// appointment per session, paused after half a minute without a touch and
// resumed on the next touch within five minutes. The page is the source of the
// touches here, so the clock lives in the page rather than in a /run file.
//
// A game calls jawnosGameSessionStart(name, screen) when play begins and on its
// controls; the screen callback answers whether the game is still on screen.
// Controls after that are heartbeat; the 30s timer posts a pause, and leaving
// (the game's window closes, the page hides, or the caller stops it) posts a
// stop.
var jawnosGameSession = {
	game: '',
	screen: null,
	last: 0,
	sent: 0,
	started: false,
	paused: false,
	timer: null,
	bound: false
};
var JAWNOS_GAME_QUIET = 30000;
var JAWNOS_GAME_TICK = 5000;
var JAWNOS_GAME_SEND_EVERY = 4000;

function jawnosGameSessionPost(game, state, at, keepalive) {
	if (!game) { return; }
	var body = JSON.stringify({ game: game, state: state, at: Math.round(at) });
	try {
		if (keepalive && navigator.sendBeacon && typeof Blob === 'function') {
			navigator.sendBeacon('/manager/game_play', new Blob([ body ], { type: 'application/json' }));
			return;
		}
		if (typeof fetch !== 'function') { return; }
		fetch('/manager/game_play', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: body,
			keepalive: !!keepalive,
			credentials: 'same-origin'
		});
	}
	catch (e) {
		// a lost beat is a shorter appointment, not a broken game
	}
}

function jawnosGameSessionGame() {
	return jawnosGameSession.game;
}

// True while a game is being played and its pane is on screen. The websocket
// beat names the game only then, so a closed window stops the heartbeat and the
// server can close the play appointment on its own.
function jawnosGameSessionActive() {
	var s = jawnosGameSession;
	if (!s.game || !s.started || s.paused) { return false; }
	if (typeof s.screen === 'function' && !s.screen()) { return false; }
	if (typeof document !== 'undefined' && document.visibilityState === 'hidden') { return false; }
	return true;
}

function jawnosGameSessionTick() {
	var s = jawnosGameSession;
	if (!s.started) { return; }
	if (typeof s.screen === 'function' && !s.screen()) {
		// The game's pane is no longer on screen: leaving Solitaire for Tarot or
		// the deck chooser is not the end of the play. Pause and keep the session
		// for the resume window; closing the window stops it.
		jawnosGameSessionPause();
		return;
	}
	if (document.visibilityState === 'hidden') {
		jawnosGameSessionPause();
		return;
	}
	if (!s.paused && Date.now() - s.last >= JAWNOS_GAME_QUIET) {
		jawnosGameSessionPause();
	}
}

function jawnosGameSessionStart(game, screen) {
	if (!game) { return; }
	// A game that is not on screen (a hidden window, a background tab) does not
	// start a session just because its init ran; the first control starts it.
	if (typeof screen === 'function' && !screen()) { return; }
	if (typeof document !== 'undefined' && document.visibilityState === 'hidden') { return; }
	var s = jawnosGameSession;
	if (s.started && s.game === game) {
		// A reopened window or a second init after a quiet spell is not a play:
		// close the old segment at its last touch (a pause, which the server
		// leaves out of the play time) and begin a new one now.
		if (Date.now() - s.last >= JAWNOS_GAME_QUIET) {
			jawnosGameSessionPause();
			s.paused = false;
			s.last = Date.now();
			s.sent = s.last;
			jawnosGameSessionPost(game, 'play', s.last);
		}
		else {
			jawnosGameSessionTouch();
		}
		return;
	}
	if (s.started) { jawnosGameSessionStop(); }
	s.game = game;
	s.screen = screen || null;
	s.last = Date.now();
	s.sent = s.last;
	s.started = true;
	s.paused = false;
	if (!s.timer) { s.timer = setInterval(jawnosGameSessionTick, JAWNOS_GAME_TICK); }
	jawnosGameSessionPost(game, 'play', s.last);
}

function jawnosGameSessionTouch() {
	var s = jawnosGameSession;
	if (!s.started) { return; }
	var now = Date.now();
	s.last = now;
	if (s.paused || now - s.sent >= JAWNOS_GAME_SEND_EVERY) {
		s.paused = false;
		s.sent = now;
		jawnosGameSessionPost(s.game, 'play', now);
	}
}

function jawnosGameSessionPause() {
	var s = jawnosGameSession;
	if (!s.started || s.paused) { return; }
	s.paused = true;
	jawnosGameSessionPost(s.game, 'pause', s.last);
}

function jawnosGameSessionStop() {
	var s = jawnosGameSession;
	if (!s.started) { return; }
	var game = s.game;
	var at = s.last;
	s.started = false;
	s.paused = false;
	s.game = '';
	s.screen = null;
	if (s.timer) { clearInterval(s.timer); s.timer = null; }
	jawnosGameSessionPost(game, 'stop', at, true);
}

function jawnosGameSessionBind() {
	var s = jawnosGameSession;
	if (s.bound) { return; }
	s.bound = true;
	if (typeof window !== 'undefined' && window.addEventListener) {
		window.addEventListener('pagehide', function () {
			if (jawnosGameSession.started) { jawnosGameSessionStop(); }
		});
	}
	if (typeof document !== 'undefined' && document.addEventListener) {
		document.addEventListener('visibilitychange', function () {
			if (document.visibilityState === 'hidden') { jawnosGameSessionPause(); }
		});
	}
}

jawnosGameSessionBind();
