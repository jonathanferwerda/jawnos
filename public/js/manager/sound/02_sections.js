// ---- the section pills ------------------------------------------------------
// Patchbay, IO, Profiles and Apps are one section at a time. The pills scroll
// sideways on a narrow window rather than wrapping, and the section a person
// leaves is remembered in this browser so opening Sound again lands where they
// were. The memory is per device on purpose: it is a view preference, not a
// house setting, so this machine and a phone can each keep their own.

var soundSectionKey = 'sound_section';
var soundSectionDefault = 'patchbay';

function soundSectionNames() {
	var names = [];
	$('#sound .sound_section_pill').each(function() {
		var name = $(this).attr('data-section');
		if (name) { names.push(name); }
	});
	return names;
}

// Show one section (and mark its pill). An unknown or missing name falls back
// to the first pill, so a remembered name from an older build cannot leave the
// window blank. `remember` is off for the restore pass: re-reading the stored
// value must never write it back over itself.
function soundSectionShow(name, remember) {
	var names = soundSectionNames();
	if (!names.length) { return; }
	if ($.inArray(name, names) < 0) { name = soundSectionDefault; }
	if ($.inArray(name, names) < 0) { name = names[0]; }
	$('#sound .sound_section_pill').each(function() {
		var on = $(this).attr('data-section') == name;
		$(this).toggleClass('is-active', on).attr('aria-selected', on ? 'true' : 'false');
	});
	$('#sound .sound_section').each(function() {
		$(this).toggleClass('is-active', $(this).attr('data-section') == name);
	});
	// The Remote pill shares the Sound widget's machine memory, so its roster is
	// read again when the section comes into view.
	if (name == 'remote' && typeof jawnosSoundTaskbarMusicLoad === 'function') {
		jawnosSoundTaskbarMusicLoad();
		jawnosSoundTaskbarMusicStateLoad();
	}
	if (remember) {
		try { localStorage.setItem(soundSectionKey, name); } catch (e) {}
	}
}

function soundSectionRestore() {
	var name = '';
	try { name = localStorage.getItem(soundSectionKey) || ''; } catch (e) { name = ''; }
	soundSectionShow(name, false);
}
