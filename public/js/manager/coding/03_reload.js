
// ---- a reload must not cost the conversation -----------------------------------
// A script change is the one update that cannot land in place, so for it the tab
// reloads (websocket.js asks first). The chat is saved the moment the page goes -
// beforeunload covers every reload, ours or a press of F5 - and put back when the
// panel is built again.

function jawnosCodingChatSave() {
	try {
		var state = {};
		$('.coding_chat').each(function () {
			var panel = $(this);
			var log = panel.find('.coding_chat_log');
			if (!log.length) { return; }
			// the live line is a snapshot of the run, not part of the conversation:
			// keep it out, or a restored log would show a finished run as working.
			// The review is the run's pending offer too - a restored log must not
			// show a commit that was decided before the reload.
			var saved = log.clone();
			saved.find('.coding_chat_now').remove();
			saved.find('.coding_chat_live').remove();
			saved.find('.coding_chat_review').remove();
			state[panel.attr('mount')] = {
				log: saved.html() || '',
				scroll: log[0] ? log[0].scrollTop : 0,
				draft: panel.find('.coding_chat_input').val() || '',
				run: panel.data('coding_run') || 0,
				steps: panel.data('coding_steps_shown') || 0
			};
		});
		sessionStorage.setItem('jawnos_coding_chat_state', JSON.stringify(state));
	} catch (e) { /* losing this is a nicety missed, never an error worth showing */ }
}

function codingChatRestore(panel) {
	if (panel.attr('spawned')) { return; }
	var state = null;
	try { state = JSON.parse(sessionStorage.getItem('jawnos_coding_chat_state') || 'null'); } catch (e) { state = null; }
	var mine = state ? state[panel.attr('mount')] : null;
	if (!mine) { return; }
	// the run and its step count come back too, or a reattach would draw the
	// lines restored above a second time
	panel.data('coding_run', mine.run || 0);
	panel.data('coding_steps_shown', mine.steps || 0);
	if (panel.find('.coding_chat_log').html()) { return; }
	var log = panel.find('.coding_chat_log');
	if (log.length && mine.log) { log.html(mine.log); }
	var input = panel.find('.coding_chat_input');
	if (input.length && !input.val() && mine.draft) { input.val(mine.draft); }
}

function codingChatRestoreScroll(mount) {
	var state = null;
	try { state = JSON.parse(sessionStorage.getItem('jawnos_coding_chat_state') || 'null'); } catch (e) { state = null; }
	var mine = state ? state[mount] : null;
	if (!mine) { return; }
	var log = codingChatPanel(mount).find('.coding_chat_log');
	if (log.length && log[0] && mine.scroll) { log[0].scrollTop = mine.scroll; }
}

window.addEventListener('beforeunload', function () { jawnosCodingChatSave(); });
