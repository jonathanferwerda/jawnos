
// The play appointment is recorded by game_session.js. The first control inside
// the game starts it; later controls only touch it.
function pipedreamScreen() {
	if (typeof document === 'undefined' || !document.getElementById) { return false; }
	var root = document.getElementById('pipedream');
	if (!root) { return false; }
	if (typeof root.getClientRects === 'function' && root.getClientRects().length === 0) { return false; }
	return (root.offsetWidth || 0) > 0 && (root.offsetHeight || 0) > 0;
}

var pipedreamTicker = null;
var pipedreamGame = null;
var pipedreamBound = false;

function pipedreamStopTicker() {
	if (pipedreamTicker) {
		clearInterval(pipedreamTicker);
		pipedreamTicker = null;
	}
}

function pipedreamBindGlobal() {
	if (pipedreamBound) { return; }
	pipedreamBound = true;
	if (typeof window !== 'undefined' && window.addEventListener) {
		window.addEventListener('pagehide', function () {
			if (pipedreamGame && pipedreamGame.pause) { pipedreamGame.pause(); }
			pipedreamStopTicker();
		});
	}
	if (typeof document !== 'undefined' && document.addEventListener) {
		document.addEventListener('visibilitychange', function () {
			if (document.visibilityState === 'hidden') {
				if (pipedreamGame && pipedreamGame.pause) { pipedreamGame.pause(); }
				pipedreamStopTicker();
			}
		});
		document.addEventListener('keydown', function (e) {
			if (pipedreamGame && pipedreamGame.key) { pipedreamGame.key(e); }
		});
	}
}

