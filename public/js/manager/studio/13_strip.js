// ===========================================================================
// The channel strip's mute and solo
// ===========================================================================
// M silences a channel; S leaves only the soloed channels audible, so every
// other strip is dimmed rather than removed - its fader stays reachable. Both
// are channel state, not markup: mixer[ch].mute and mixer[ch].solo are what the
// audio graph and the song read, and the buttons only paint them. The engine's
// studioApplyMuteSolo() (another part) applies that state to the mix and is
// optional here, so this part still loads on its own.

// Paint every strip from mixer state. A channel is dimmed when any channel is
// soloed and this one is not; nothing is hidden. Returns whether anything is
// soloed, which is the same test the dimming uses.
function studioStripMuteSoloRender() {
	var soloed = false;
	var channels = [];
	$.each(mixer, function (key, state) {
		if (!/^[0-9]+$/.test(String(key))) { return; }
		var ch = parseInt(key, 10);
		if (!(ch > 0)) { return; }
		channels.push(ch);
		if (state && state.solo) { soloed = true; }
	});
	$.each(channels, function (i, ch) {
		var state = mixer[ch] || {};
		$('.studio_strip_mute[channel="' + ch + '"]').attr('aria-pressed', state.mute ? 'true' : 'false');
		$('.studio_strip_solo[channel="' + ch + '"]').attr('aria-pressed', state.solo ? 'true' : 'false');
		$('#studio_track_row_' + ch + ', #studio_mixer_strips .channel_' + ch)
			.toggleClass('studio_solo_muted', soloed && !state.solo);
	});
	return soloed;
}

// M and S are <button>s, so Enter and Space click them already. A click writes
// the channel's state, repaints every strip (this one for its pressed look, the
// others for the solo dimming), lets the engine apply the mix, and saves the
// song. mixer[ch] is created if a click beats the track's own setup.
$(document).on('click', '.studio_strip_mute', function () {
	var ch = parseInt($(this).attr('channel'), 10);
	if (!(ch > 0)) { return; }
	if (!mixer[ch]) { mixer[ch] = {}; }
	mixer[ch].mute = !mixer[ch].mute;
	studioStripMuteSoloRender();
	if (typeof studioApplyMuteSolo === 'function') { studioApplyMuteSolo(); }
	studioSaver();
});

$(document).on('click', '.studio_strip_solo', function () {
	var ch = parseInt($(this).attr('channel'), 10);
	if (!(ch > 0)) { return; }
	if (!mixer[ch]) { mixer[ch] = {}; }
	mixer[ch].solo = !mixer[ch].solo;
	studioStripMuteSoloRender();
	if (typeof studioApplyMuteSolo === 'function') { studioApplyMuteSolo(); }
	studioSaver();
});

// studioInit calls this once the window's markup is on the page, so a freshly
// opened window shows mixer state, not the markup's defaults.

// Loading a song restores mixer[ch].mute/solo outside this part, which then
// asks for one repaint with this event instead of reaching into the strip.
// studioStripMuteSoloRender() is the same call, for a caller that has it.
$(document).on('studio:mute-solo', function () { studioStripMuteSoloRender(); });

// ---- the strip's own height -------------------------------------------------
// The fader is a percentage of the strip, and a hidden or freshly restored
// window measures zero. Resolve the strips box against the panel explicitly, so
// the first paint after a restore has the same fader height as a reopened one.
function studioMixerRelayout() {
	var panel = document.getElementById('studio_mixer');
	var strips = document.getElementById('studio_mixer_strips');
	if (!panel || !strips) { return; }
	if (!$('#studio_mixer').is(':visible')) { return; }
	var bar = panel.querySelector('.studio_panel_bar');
	var pad = parseFloat(getComputedStyle(panel).paddingBottom) || 0;
	var available = panel.clientHeight - (bar ? bar.offsetHeight : 0) - pad;
	if (available > 0) { strips.style.height = available + 'px'; }
	else { strips.style.height = ''; }
}

var studioMixerLayoutObserver = null;
var studioMixerLayoutPanel = null;

// Follow the mixer window as it is resized, maximized or restored. The observer
// is re-created when a reopened Studio window brings a new panel node.
function studioMixerObserveLayout() {
	var panel = document.getElementById('studio_mixer');
	if (!panel) { return; }
	if (typeof ResizeObserver === 'function') {
		if (!(studioMixerLayoutObserver && studioMixerLayoutPanel === panel)) {
			if (studioMixerLayoutObserver) { studioMixerLayoutObserver.disconnect(); }
			studioMixerLayoutPanel = panel;
			studioMixerLayoutObserver = new ResizeObserver(function () { studioMixerRelayout(); });
			studioMixerLayoutObserver.observe(panel);
		}
	}
	studioMixerRelayout();
}
