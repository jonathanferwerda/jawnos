/* [[js-split]]
   twirl.js is part 1. The rest live in twirl/ in name order:
     01_twirl_game.js  - twirlGame(), the game instance, and the startup call
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
var twirlRunning = false;
var twirlKeysBound = false;
var twirlControls = null;
var twirlInstance = null;

function twirlKeyCommand(code) {
	if (code == 37) { return 'left'; }
	if (code == 39) { return 'right'; }
	if (code == 40) { return 'down'; }
	if (code == 38) { return 'rotate'; }
	if (code == 124) { return 'rotate_left'; } // F13: the B button
	if (code == 32) { return 'drop'; }
	return null;
}

