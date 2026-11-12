// The house's silence, in the browser.
//
// The server mutes the machine's own mixer; this keeps the browser's half quiet
// too. Every audio and video element is muted and forced silent while the house
// is quiet, including media a window creates after silence began and the WebRTC
// call audio the screening panel holds.
//
// The state is one house-wide row. The manager page polls /manager/silence, and
// the server also pushes jawnosSilence over the console channel, so a phone and
// a laptop go quiet at the same moment.
var jawnosSilenceState = { active: false };

function jawnosSilenceActive() {
	return !!jawnosSilenceState.active;
}

function jawnosSilenceQuietMedia(el) {
	if (!el || el.nodeType !== 1) { return; }
	if (!el.__jawnosSilenceSaved) {
		el.__jawnosSilenceSaved = { muted: !!el.muted, volume: el.volume };
	}
	try { el.muted = true; el.volume = 0; } catch (e) { }
}

function jawnosSilenceRestoreMedia(el) {
	var saved = el && el.__jawnosSilenceSaved;
	if (!saved) { return; }
	try { el.muted = !!saved.muted; el.volume = saved.volume; } catch (e) { }
	try { delete el.__jawnosSilenceSaved; } catch (e) { }
}

function jawnosSilenceScan(root) {
	var scope = root || document;
	if (!scope || !scope.querySelectorAll) { return; }
	scope.querySelectorAll('audio, video').forEach(function (el) {
		if (jawnosSilenceActive()) { jawnosSilenceQuietMedia(el); }
		else { jawnosSilenceRestoreMedia(el); }
	});
}

// Accept the status route's { active, state }, the console push's object, or a
// bare 1/0 from an older caller.
function jawnosSilenceApply(state) {
	if (typeof state === 'string') {
		try { state = JSON.parse(state); } catch (e) { state = {}; }
	}
	var active = false;
	if (typeof state === 'number') { active = !!state; }
	else if (typeof state === 'boolean') { active = state; }
	else if (state && typeof state === 'object') { active = !!state.active; }
	jawnosSilenceState = (state && typeof state === 'object') ? state : { active: active };
	jawnosSilenceState.active = active;
	jawnosSilenceScan(document);
	$('body').attr('data-jawnos-silence', active ? 'on' : 'off');
	return active;
}

function jawnosSilenceFetch() {
	$.ajax({
		url: '/manager/silence',
		type: 'GET',
		dataType: 'json',
		cache: false,
		success: function (res) {
			jawnosSilenceApply((res && res.state) ? res.state : res);
		},
		error: function () { }
	});
}

// A player created while the house is quiet is muted as it arrives.
function jawnosSilenceWatch() {
	if (!window.MutationObserver || !document.body) { return; }
	var observer = new MutationObserver(function (records) {
		if (!jawnosSilenceActive()) { return; }
		records.forEach(function (record) {
			record.addedNodes.forEach(function (node) {
				if (node && node.nodeType === 1) { jawnosSilenceScan(node); }
			});
		});
	});
	observer.observe(document.body, { childList: true, subtree: true });
}

(function () {
	if (!window.HTMLMediaElement) { return; }
	var play = HTMLMediaElement.prototype.play;
	HTMLMediaElement.prototype.play = function () {
		if (jawnosSilenceActive()) { jawnosSilenceQuietMedia(this); }
		return play.apply(this, arguments);
	};
})();

$(document).on('play volumechange', 'audio, video', function () {
	if (jawnosSilenceActive()) { jawnosSilenceQuietMedia(this); }
});

$(document).ready(function () {
	jawnosSilenceWatch();
	jawnosSilenceFetch();
	setInterval(jawnosSilenceFetch, 15000);
	document.addEventListener('visibilitychange', function () {
		if (!document.hidden) { jawnosSilenceFetch(); }
	});
});
