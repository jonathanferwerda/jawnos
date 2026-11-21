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
