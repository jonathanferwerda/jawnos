// The voice card, and the activity stamp that chooses the screen it lands on.
//
// Every page records that the person is at this machine when it sees a mouse
// move, a key, a tap, the wheel or a real movement of a phone or tablet. The
// server keeps one stamp per device (synced, so any machine can read it) and
// sends a voiceCard command when a voice turn gets an answer; only the page
// whose device uuid matches draws it. It is a transient toast, not the
// screening panel: it leaves after twelve seconds.

var jawnActivity = { at: 0 };

function jawnActivityPing(force) {
	var now = Date.now();
	var gap = force ? 5000 : 30000;
	if (now - jawnActivity.at < gap) { return; }
	if (document.visibilityState === 'hidden') { return; }
	var uuid = '';
	try { uuid = (typeof jawnDeviceUuid === 'function') ? jawnDeviceUuid() : ''; } catch (e) { uuid = ''; }
	if (!uuid) { return; }
	jawnActivity.at = now;
	$.post('/manager/activity', { device_uuid: uuid, timestamp: now });
}

$(document).on('mousedown keydown touchstart pointerdown', function () { jawnActivityPing(true); });
$(document).on('mousemove wheel', function () { jawnActivityPing(false); });
$(document).on('visibilitychange', function () {
	if (document.visibilityState === 'visible') { jawnActivityPing(true); }
});
window.addEventListener('deviceorientation', function () { jawnActivityPing(false); }, true);
$(function () { jawnActivityPing(true); });

var jawnVoiceCardTimer = null;

function jawnVoiceCardShow(data) {
	data = data || {};
	var target = String(data.device_uuid || '');
	var own = '';
	try { own = (typeof jawnDeviceUuid === 'function') ? jawnDeviceUuid() : ''; } catch (e) { own = ''; }
	if (document.visibilityState === 'hidden') { return; }
	if (target && target !== own) { return; }
	if (!target && !document.hasFocus()) { return; }
	var question = String(data.question || '');
	var reply = String(data.reply || '');
	if (!question && !reply) { return; }
	var card = $('#jawn_voice_card');
	if (!card.length) {
		card = $('<div id="jawn_voice_card" class="jawn_voice_card"></div>');
		card.append($('<div class="jawn_voice_card_head"></div>')
			.append($('<button class="jawn_voice_card_close" hint="Hide"></button>').text(jawnosT('Hide'))));
		card.append($('<div class="jawn_voice_card_question"></div>'));
		card.append($('<div class="jawn_voice_card_reply"></div>'));
		$('body').append(card);
		card.on('click', '.jawn_voice_card_close', function () { jawnVoiceCardHide(); });
	}
	card.find('.jawn_voice_card_question').text(question);
	card.find('.jawn_voice_card_reply').text(reply);
	card.addClass('on');
	if (jawnVoiceCardTimer) { clearTimeout(jawnVoiceCardTimer); }
	jawnVoiceCardTimer = setTimeout(jawnVoiceCardHide, 12000);
}

function jawnVoiceCardHide() {
	if (jawnVoiceCardTimer) { clearTimeout(jawnVoiceCardTimer); jawnVoiceCardTimer = null; }
	$('#jawn_voice_card').removeClass('on');
}
