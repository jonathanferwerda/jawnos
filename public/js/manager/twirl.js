/* [[js-split]]
   twirl.js is part 1. The rest live in twirl/ in name order:
     01_twirl_game.js  - twirlGame() and the startup call
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
var twirlRunning = false;
var twirlKeysBound = false;
var twirlControls = null;
var twirlHeld = {};
var twirlDas = null;
var twirlRepeat = null;
var twirlDasDelay = 150;   // pause after first move before auto-repeat begins
var twirlRepeatDelay = 50; // gap between repeated moves while a key is held

function twirlKeyCommand(code) {
	if (code == 37) { return 'left'; }
	if (code == 39) { return 'right'; }
	if (code == 40) { return 'down'; }
	if (code == 38) { return 'rotate'; }
	if (code == 32) { return 'drop'; }
	return null;
}

function twirlStartRepeat() {
	if (twirlDas) { clearTimeout(twirlDas); twirlDas = null; }
	if (twirlRepeat) { clearInterval(twirlRepeat); twirlRepeat = null; }
	twirlDas = setTimeout(function () {
		twirlDas = null;
		twirlRepeat = setInterval(twirlRepeatStep, twirlRepeatDelay);
	}, twirlDasDelay);
}

function twirlStopRepeat() {
	if (twirlDas) { clearTimeout(twirlDas); twirlDas = null; }
	if (twirlRepeat) { clearInterval(twirlRepeat); twirlRepeat = null; }
}

function twirlRepeatStep() {
	if (!twirlControls) { return; }
	if (twirlHeld['left']) { twirlControls.action('left'); }
	else if (twirlHeld['right']) { twirlControls.action('right'); }
	else if (twirlHeld['down']) { twirlControls.action('down'); }
	else {
		clearInterval(twirlRepeat);
		twirlRepeat = null;
	}
}

