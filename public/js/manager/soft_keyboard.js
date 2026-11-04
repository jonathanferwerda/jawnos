/* [[js-split]]
   soft_keyboard.js is part 1. The rest live in soft_keyboard/ in name order:
     01_scroll_dictate.js  - scroll, title, mode, shift, dictate and room detection
     02_ime_input.js  - IME sync, insert, backspace/repeat, enter, calc and history
     03_convert.js  - unit converter, measure picker and suggestions
     04_eval_text.js  - eval, magnify, key/char/press, sweep and text drag
     05_vault_ime.js  - vault, imeStart, window.ime* and init
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
// The JawnOS on-screen keyboard.
//
// One dock serves every editable field in the manager: letters, a calculator for
// number fields, and a page of special characters. It suppresses the platform
// keyboard with inputmode="none", so the viewport never changes shape. On a phone
// it is the default; a desk keeps its hardware keyboard, so the dock stays closed
// there (a real key press proves the keyboard) and the unit conversions ride
// above the field being typed in instead. The dock is one explicit ask away (the
// Chat keyboard button or the dock's keyboard icon).
//
// Placement: inside the Chat composer it is an ordinary block (the composer makes
// room for it); inside another window it rides the window's foot; outside a
// window it is fixed above the taskbar. The focused field is scrolled clear of it.

var jawnSoftField = null;
// On a desk the dock is an explicit ask, so once it is up it holds the input:
// another top-level window coming and going must not take the keys away. It
// stays until another field takes them or the dock is closed. A phone keeps the
// follow-the-field behaviour.
var jawnSoftSticky = false;
var jawnSoftMode = 'letters';
var jawnSoftShift = false;
var jawnSoftNumeric = false;
var jawnSoftContext = '';
var jawnSoftExpr = '';
var jawnSoftSetting = false;
var jawnSoftKeyAt = 0;
var jawnSoftHideTimer = null;
var jawnSoftSlideTimer = null;
var jawnSoftSlideAt = 0;
// A drag across a field focuses it so the selection is visible; that focus is
// not a request for the keyboard, and neither is the click that ends the drag.
var jawnSoftDragFocus = false;
var jawnSoftDragClick = false;
// A desk's keyboard is the one to type with. A browser cannot enumerate input
// devices, but a fine pointer that hovers with no phone-shaped screen is a
// desk, and one trusted key press settles it. `forced` is the person asking
// for the dock in this visit (the Chat button or the dock's keyboard icon).
var jawnSoftHardware = false;
var jawnSoftForced = false;
try { jawnSoftHardware = localStorage.getItem('jawn_soft_keyboard_hw') == 'on'; } catch (err) {}
// The Android input method serves this same file on a page of its own and adds
// window.JawnIme before it parses. There is no DOM field to type into then: the
// keys commit through the bridge, and the service reports the editor's text
// back after each edit so the conversion and recommendation rows read it.
var jawnSoftIme = !!window.jawnSoftIme;
var jawnImeText = '';

// ---- layouts ---------------------------------------------------------------
// The keys a phone's own keyboard puts where. A layout is rows of tokens: a
// single character is a letter, and 'shift', 'backspace', 'enter', 'space' and
// 'sym' name the keys that edit or change layer. `extra` is a scrollable row of
// a language's accented letters (or the characters another script needs), kept
// out of the letter rows so the familiar shape stays. `lang` is what dictation
// listens for. `cased: false` marks a script with no upper case, so the layout
// carries no shift key.
var JAWN_SOFT_LAYOUTS = [
	{
		id: 'samsung', group: 'phone', name: 'Samsung (One UI)', note: 'Numbers on top', lang: 'en-US',
		rows: [
			['1','2','3','4','5','6','7','8','9','0'],
			['q','w','e','r','t','y','u','i','o','p'],
			['a','s','d','f','g','h','j','k','l'],
			['shift','z','x','c','v','b','n','m','backspace'],
			['sym',',','space','.','enter']
		]
	},
	{
		id: 'ios', group: 'phone', name: 'iOS', note: 'No number row', lang: 'en-US',
		rows: [
			['q','w','e','r','t','y','u','i','o','p'],
			['a','s','d','f','g','h','j','k','l'],
			['shift','z','x','c','v','b','n','m','backspace'],
			['sym',',','space','.','enter']
		]
	},
	{
		id: 'gboard', group: 'phone', name: 'Gboard (Pixel)', note: 'Numbers on top', lang: 'en-US',
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['q','w','e','r','t','y','u','i','o','p'],
			['a','s','d','f','g','h','j','k','l'],
			['shift','z','x','c','v','b','n','m','backspace'],
			['sym',',','space','.','enter']
		]
	},
	{
		id: 'qwerty', group: 'phone', name: 'QWERTY (US)', note: 'Numbers on top', lang: 'en-US',
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['q','w','e','r','t','y','u','i','o','p'],
			['a','s','d','f','g','h','j','k','l',';'],
			['shift','z','x','c','v','b','n','m',',','.','/'],
			['sym','space','enter']
		]
	},
	{
		id: 'azerty', group: 'language', name: 'Français', note: 'AZERTY', lang: 'fr-FR',
		extra: ['é','è','ê','ë','à','â','ç','ô','û','î','ï','œ','ù','ÿ'],
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['a','z','e','r','t','y','u','i','o','p'],
			['q','s','d','f','g','h','j','k','l','m'],
			['shift','w','x','c','v','b','n',',','backspace'],
			['sym','space','.','enter']
		]
	},
	{
		id: 'qwertz', group: 'language', name: 'Deutsch', note: 'QWERTZ', lang: 'de-DE',
		extra: ['ä','ö','ü','ß','€'],
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['q','w','e','r','t','z','u','i','o','p','ü'],
			['a','s','d','f','g','h','j','k','l','ö','ä'],
			['shift','y','x','c','v','b','n','m','ß','backspace'],
			['sym',',','space','.','enter']
		]
	},
	{
		id: 'spanish', group: 'language', name: 'Español', note: 'Spanish', lang: 'es-ES',
		extra: ['á','é','í','ó','ú','ü','ñ','¿','¡'],
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['q','w','e','r','t','y','u','i','o','p'],
			['a','s','d','f','g','h','j','k','l','ñ'],
			['shift','z','x','c','v','b','n','m','backspace'],
			['sym',',','space','.','enter']
		]
	},
	{
		id: 'italian', group: 'language', name: 'Italiano', note: 'Italian', lang: 'it-IT',
		extra: ['à','è','é','ì','ò','ù'],
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['q','w','e','r','t','y','u','i','o','p'],
			['a','s','d','f','g','h','j','k','l'],
			['shift','z','x','c','v','b','n','m','backspace'],
			['sym',',','space','.','enter']
		]
	},
	{
		id: 'portuguese', group: 'language', name: 'Português', note: 'Portuguese', lang: 'pt-BR',
		extra: ['á','â','ã','à','é','ê','í','ó','ô','õ','ú','ü','ç'],
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['q','w','e','r','t','y','u','i','o','p'],
			['a','s','d','f','g','h','j','k','l','ç'],
			['shift','z','x','c','v','b','n','m','backspace'],
			['sym',',','space','.','enter']
		]
	},
	{
		id: 'turkish', group: 'language', name: 'Türkçe', note: 'Turkish Q', lang: 'tr-TR',
		extra: ['â','î','û','ç','ğ','ı','ö','ş','ü'],
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['q','w','e','r','t','y','u','ı','o','p','ğ','ü'],
			['a','s','d','f','g','h','j','k','l','ş','i'],
			['shift','z','x','c','v','b','n','m','ö','ç','backspace'],
			['sym',',','space','.','enter']
		]
	},
	{
		id: 'russian', group: 'language', name: 'Русский', note: 'Cyrillic', lang: 'ru-RU',
		extra: ['ё'],
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['й','ц','у','к','е','н','г','ш','щ','з','х','ъ'],
			['ф','ы','в','а','п','р','о','л','д','ж','э'],
			['shift','я','ч','с','м','и','т','ь','б','ю','backspace'],
			['sym',',','space','.','enter']
		]
	},
	{
		id: 'arabic', group: 'language', name: 'العربية', note: 'Arabic', lang: 'ar-SA', cased: false,
		extra: ['ً','ٌ','ٍ','َ','ُ','ِ','ّ','ْ','؟','،','؛'],
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['ض','ص','ث','ق','ف','غ','ع','ه','خ','ح','ج','د'],
			['ش','س','ي','ب','ل','ا','ت','ن','م','ك','ط'],
			['ئ','ء','ؤ','ر','لا','ى','ة','و','ز','ظ','backspace'],
			['sym','،','space','.','enter']
		]
	},
	{
		id: 'hindi', group: 'language', name: 'हिन्दी', note: 'Devanagari', lang: 'hi-IN', cased: false,
		extra: ['घ','ङ','छ','झ','ञ','ठ','ढ','ण','थ','ध','फ','श','ष','ह','ऱ','ॐ'],
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['ौ','ै','ा','ी','ू','ब','ह','ग','द','ज','ड','़'],
			['ो','े','्','ि','ु','प','र','क','त','च','ट'],
			['ॉ','ं','म','न','व','ल','स','य','अ','ख','भ','backspace'],
			['sym',',','space','.','enter']
		]
	},
	{
		id: 'bengali', group: 'language', name: 'বাংলা', note: 'Bengali', lang: 'bn-BD', cased: false,
		extra: ['অ','আ','ই','ঈ','উ','ঊ','ঋ','এ','ঐ','ও','ঔ','া','ি','ী','ু','ূ','ৃ','ে','ৈ','ো','ৌ','্','ং','ঃ','ঁ'],
		rows: [
			['1','2','3','4','5','6','7','8','9','0','backspace'],
			['ক','খ','গ','ঘ','ঙ','চ','ছ','জ','ঝ','ঞ'],
			['ট','ঠ','ড','ঢ','ণ','ত','থ','দ','ধ','ন'],
			['প','ফ','ব','ভ','ম','য','র','ল','শ','ষ'],
			['sym','স','হ','ড়','ঢ়','য়','ৎ','space','enter']
		]
	}
];

var jawnSoftLayoutId = null;
var jawnSoftListening = false;

function softKbLayoutFind(id) {
	for (var i = 0; i < JAWN_SOFT_LAYOUTS.length; i++) {
		if (JAWN_SOFT_LAYOUTS[i].id === id) { return JAWN_SOFT_LAYOUTS[i]; }
	}
	return null;
}

function softKbLayoutDefault() {
	var ua = navigator.userAgent || '';
	if (/iPhone|iPad|iPod/i.test(ua)) { return 'ios'; }
	if (/Android/i.test(ua)) { return 'samsung'; }
	return 'qwerty';
}

function softKbLayout() {
	if (jawnSoftLayoutId == null) {
		try { jawnSoftLayoutId = localStorage.getItem('jawn_soft_layout') || ''; } catch (err) { jawnSoftLayoutId = ''; }
		if (!softKbLayoutFind(jawnSoftLayoutId)) { jawnSoftLayoutId = softKbLayoutDefault(); }
	}
	return softKbLayoutFind(jawnSoftLayoutId) || JAWN_SOFT_LAYOUTS[0];
}

function softKbUpper(ch, layout) {
	try { return ch.toLocaleUpperCase(layout.lang || 'en'); }
	catch (err) { try { return ch.toUpperCase(); } catch (err2) { return ch; } }
}

function softKbHtml(text) {
	return String(text == null ? '' : text)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function softKbKeyHtml(tok, layout, shift, extra) {
	var esc = softKbHtml;
	if (tok == 'shift') {
		return '<button type="button" class="soft_kb_key soft_kb_mod' + (shift ? ' active' : '') + '" data-kb_key="shift" aria-label="' + esc(softKbLabel('Shift')) + '">⇧</button>';
	}
	if (tok == 'backspace') {
		return '<button type="button" class="soft_kb_key soft_kb_mod" data-kb_key="backspace" aria-label="' + esc(softKbLabel('Backspace')) + '">⌫</button>';
	}
	if (tok == 'enter') {
		return '<button type="button" class="soft_kb_key soft_kb_mod" data-kb_key="enter" aria-label="' + esc(softKbLabel('New line')) + '">⏎</button>';
	}
	if (tok == 'space') {
		var space_label = softKbServerLabel('space', 'Space');
		return '<button type="button" class="soft_kb_key soft_kb_space" data-kb_key="space" aria-label="' + esc(space_label) + '">' + esc(space_label) + '</button>';
	}
	if (tok == 'sym') {
		return '<button type="button" class="soft_kb_key soft_kb_mod" data-kb_mode="symbols">#+=</button>';
	}
	var label = shift ? softKbUpper(tok, layout) : tok;
	return '<button type="button" class="soft_kb_key' + (extra ? ' soft_kb_extra_key' : ' soft_kb_letter') + '" data-kb_key="' + esc(tok) + '" aria-label="' + esc(label) + '">' + esc(label) + '</button>';
}

// Draw the letters panel from the chosen layout. Shift is a re-draw rather than
// a walk over the keys, so a layout can carry its own upper-case shape.
function softKbLayoutRender() {
	var host = $('#soft_kb_letters_rows');
	if (!host.length) { return; }
	var layout = softKbLayout();
	var shift = !!jawnSoftShift && layout.cased !== false;
	var rows = [];
	if (layout.extra && layout.extra.length) { rows.push({ extra: true, keys: layout.extra }); }
	(layout.rows || []).forEach(function (r) { rows.push({ extra: false, keys: r }); });
	var html = '';
	rows.forEach(function (r) {
		html += '<div class="soft_kb_row' + (r.extra ? ' soft_kb_extra_row' : '') + '">';
		r.keys.forEach(function (tok) { html += softKbKeyHtml(tok, layout, shift, r.extra); });
		html += '</div>';
	});
	host.html(html);
}

function softKbLayoutsRender() {
	var host = $('#soft_kb_layouts_list');
	if (!host.length) { return; }
	var current = softKbLayout().id;
	var groups = [
		{ key: 'phone', label: softKbLabel('Phone keyboards') },
		{ key: 'language', label: softKbLabel('Other languages') }
	];
	var html = '';
	groups.forEach(function (g) {
		var items = JAWN_SOFT_LAYOUTS.filter(function (l) { return l.group === g.key; });
		if (!items.length) { return; }
		html += '<div class="soft_kb_layout_group"><div class="soft_kb_layout_group_label">' + softKbHtml(g.label) + '</div><div class="soft_kb_layout_grid">';
		items.forEach(function (l) {
			html += '<button type="button" class="soft_kb_layout_item' + (l.id === current ? ' active' : '') + '" data-kb_layout="' + softKbHtml(l.id) + '">'
				+ '<span class="soft_kb_layout_name">' + softKbHtml(l.name) + '</span>'
				+ '<span class="soft_kb_layout_note">' + softKbHtml(l.note ? softKbLabel(l.note) : '') + '</span></button>';
		});
		html += '</div></div>';
	});
	host.html(html);
}

function softKbLayoutsToggle(open) {
	var panel = $('#soft_kb_layouts');
	if (!panel.length) { return; }
	var show = (open == null) ? panel.prop('hidden') : !!open;
	if (show && jawnVault.open) { softKbVaultClose(); }
	if (show) { softKbLayoutsRender(); }
	panel.prop('hidden', !show);
	$('#soft_kb_layout_button').attr('aria-expanded', show ? 'true' : 'false').toggleClass('active', show);
	softKbReserve();
}

function softKbLayoutSet(id) {
	var layout = softKbLayoutFind(id);
	if (!layout) { return; }
	if (jawnSoftListening) { softKbDictateStop(); }
	jawnSoftLayoutId = id;
	try { localStorage.setItem('jawn_soft_layout', id); } catch (err) {}
	jawnSoftShift = false;
	softKbLayoutRender();
	softKbLayoutsToggle(false);
	softKbTitleUpdate();
}

// The dock's keyboard and calculator icons open this dock now instead of the
// old floating panels. With a field focused it types there; with none it opens
// anyway, ready for the next field that is touched (the calculator needs no
// field at all).
function softKbDockOpen(mode) {
	var want = (mode == 'calc') ? 'calc' : 'letters';
	if (softKbVisible() && jawnSoftMode == want) { jawnSoftForced = false; softKbHide(); return; }
	softKbForce();
	jawnMeasureHide();
	var dock = $('#jawn_soft_keyboard');
	if (!dock.length) { return; }
	var field = (jawnSoftField && document.contains(jawnSoftField)) ? jawnSoftField : null;
	if (!field && document.activeElement && softKbEditable(document.activeElement)) {
		field = softKbRoot(document.activeElement);
	}
	if (field) {
		softKbShow(field);
		softKbModeSet(want);
		return;
	}
	softKbPlace(null);
	dock.prop('hidden', false).attr('aria-hidden', 'false');
	$('body').addClass('soft_kb_open');
	jawnSoftContext = '';
	jawnSoftNumeric = false;
	softKbModeSet(want);
	softKbReserve();
	// the calculator needs no field: the dock itself holds the input from here
	if (softKbDesk()) { softKbStickySet(true); }
}

function softKbOn() {
	// the input method page is the keyboard, always: there is no desk to test
	if (jawnSoftIme) { return true; }
	var stored = null;
	try { stored = localStorage.getItem('jawn_soft_keyboard'); } catch (err) {}
	if (stored == 'off') { return false; }
	if (jawnSoftHardware) { return false; }
	if (jawnSoftForced) { return true; }
	// a desk with its own keyboard never raises the dock on its own, even if it
	// was left on last time; only an explicit ask (below) brings it back
	if (softKbDesk()) { return false; }
	if (stored == 'on') { return true; }
	if (typeof windowPhoneChecker == 'function' && windowPhoneChecker()) { return true; }
	// A tablet is a touch device with no hovering pointer, so the dock is its
	// keyboard exactly as it is a phone's. softKbDesk above already refused a
	// real desk; this is the touch case the phone test misses.
	if (/Android|iPad|Tablet/i.test(navigator.userAgent || '')) { return true; }
	return /Android|iPhone|iPad|iPod|Tablet|Mobile/i.test(navigator.userAgent || '');
}

// A desk, as far as the page can tell: not a phone by the manager's own test,
// and a fine pointer that hovers (a mouse or trackpad). A touch laptop still
// counts as a desk - its screen is not what the dock is for.
function softKbDesk() {
	if (typeof windowPhoneChecker == 'function' && windowPhoneChecker()) { return false; }
	// An Android or iPad tablet is a touch device even when it reports a
	// hovering S Pen or a keyboard case; the dock is the keyboard it should get.
	if (/Android|iPad|Tablet/i.test(navigator.userAgent || '')) { return false; }
	try {
		if (window.matchMedia) {
			if (window.matchMedia('(any-pointer: coarse)').matches) { return false; }
			return window.matchMedia('(hover: hover) and (any-pointer: fine)').matches;
		}
	} catch (err) {}
	return false;
}

// Remember that a real key was typed, and put the dock away. The flag is kept
// so the next focus does not bring it straight back; a finger on a phone clears
// it again (see the touchstart handler), and an explicit ask clears it here.
function softKbHardwareMark() {
	if (jawnSoftHardware) { return; }
	jawnSoftHardware = true;
	try { localStorage.setItem('jawn_soft_keyboard_hw', 'on'); } catch (err) {}
	if (softKbVisible()) { softKbHide(); }
}

function softKbHardwareClear() {
	jawnSoftHardware = false;
	try { localStorage.setItem('jawn_soft_keyboard_hw', 'off'); } catch (err) {}
}

function softKbForce() {
	jawnSoftForced = true;
	softKbHardwareClear();
	try { localStorage.setItem('jawn_soft_keyboard', 'on'); } catch (err) {}
}

function softKbRoot(el) {
	if (!el) { return null; }
	if (el.isContentEditable) { return el.closest('[contenteditable]') || el; }
	return el;
}

function softKbEditable(el) {
	if (!el || el.nodeType != 1) { return false; }
	if (el.disabled || el.readOnly) { return false; }
	if (el.getAttribute('data-soft_keyboard') == 'off') { return false; }
	if (el.isContentEditable) { return true; }
	var tag = el.tagName.toLowerCase();
	if (tag == 'textarea') { return true; }
	if (tag != 'input') { return false; }
	var type = (el.getAttribute('type') || 'text').toLowerCase();
	return ['text', 'search', 'email', 'url', 'password', 'tel', 'number'].indexOf(type) >= 0;
}

function softKbNumeric(el) {
	if (!el) { return false; }
	var type = (el.getAttribute('type') || '').toLowerCase();
	var mode = (el.getAttribute('inputmode') || el.getAttribute('data-soft_inputmode') || '').toLowerCase();
	return type == 'number' || mode == 'numeric' || mode == 'decimal';
}

function softKbSuppress(el) {
	el = softKbRoot(el);
	if (!el || el.getAttribute('data-soft_inputmode') != null) { return; }
	el.setAttribute('data-soft_inputmode', el.getAttribute('inputmode') || '');
	el.setAttribute('inputmode', 'none');
	if (el.isContentEditable) { el.setAttribute('virtualkeyboardpolicy', 'manual'); }
}

function softKbRestore(el) {
	el = softKbRoot(el);
	if (!el) { return; }
	var prior = el.getAttribute('data-soft_inputmode');
	if (prior != null) {
		if (prior) { el.setAttribute('inputmode', prior); }
		else { el.removeAttribute('inputmode'); }
		el.removeAttribute('data-soft_inputmode');
	}
	if (el.isContentEditable) { el.removeAttribute('virtualkeyboardpolicy'); }
}

function softKbLabel(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

// A label the server already translated as a core interface label (the space
// bar's word is one). Parsed once from the template's own data block.
var jawnSoftServerLabels = null;
function softKbServerLabel(key, text) {
	if (jawnSoftServerLabels == null) {
		jawnSoftServerLabels = {};
		var host = document.getElementById('soft_kb_labels');
		if (host) {
			try { jawnSoftServerLabels = JSON.parse(host.textContent || '{}') || {}; }
			catch (err) { jawnSoftServerLabels = {}; }
		}
	}
	var label = jawnSoftServerLabels[key];
	return (label != null && label !== '') ? label : softKbLabel(text);
}

// What kind of field the dock is typing into. The class, name and placeholder
// are the house's own conventions ("ago", "duration", "warranty", "schedule",
// "notes"), and a `time` input is a timestamp written in words. The answer
// decides both the recommendation row and whether a typed "5m" is minutes or
// metres.
function softKbContext(el) {
	if (!el) { return ''; }
	if ((el.getAttribute('type') || '').toLowerCase() == 'password') { return 'password'; }
	var raw = [
		el.id,
		el.getAttribute('name'),
		el.getAttribute('placeholder'),
		el.getAttribute('text'),
		el.getAttribute('attribute'),
		el.getAttribute('hint'),
		el.getAttribute('data-context'),
		el.className
	].join(' ').toLowerCase();
	var tokens = raw.split(/[^a-z0-9]+/);
	var has = function (t) { return tokens.indexOf(t) >= 0; };
	if (has('duration')) { return 'duration'; }
	if (has('warranty')) { return 'warranty'; }
	if (has('schedule')) { return 'schedule'; }
	if (has('timestamp') || has('ago') || has('time')) { return 'when'; }
	if (has('notes') || has('note')) { return 'notes'; }
	if (el.id == 'message' || $(el).closest('.chat_shell').length) { return 'chat'; }
	if (softKbNumeric(el)) { return 'number'; }
	return 'text';
}

// The dock slides its own height in from the foot of the screen. `soft_kb_up`
// is the raised position, and `hidden` is set only once it has finished going
// down, so a hide is not cut off halfway. A show that arrives while it is
// leaving clears the timer and rides it back up from wherever it is.
function softKbSlideMs() {
	try {
		if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) { return 0; }
	} catch (err) {}
	return 220;
}

function softKbSlideUp(dock) {
	clearTimeout(jawnSoftSlideTimer);
	jawnSoftSlideTimer = null;
	dock.prop('hidden', false).attr('aria-hidden', 'false');
	if (dock.hasClass('soft_kb_up')) { return; }
	// force the closed position to be laid out first, or the transition has no
	// start to run from when the element has only just left display:none
	void dock[0].offsetHeight;
	dock.addClass('soft_kb_up');
	jawnSoftSlideAt = Date.now();
	// the box is measured from the keyboard's top edge once it has settled;
	// while it rises that edge is still on its way up from the screen's foot
	setTimeout(function () {
		if (dock.prop('hidden') || !dock.hasClass('soft_kb_up')) { return; }
		softKbReserve();
	}, softKbSlideMs() + 60);
}

function softKbSlideDown(dock) {
	clearTimeout(jawnSoftSlideTimer);
	jawnSoftSlideTimer = null;
	dock.removeClass('soft_kb_up');
	if (dock.prop('hidden')) { return; }
	jawnSoftSlideTimer = setTimeout(function () {
		jawnSoftSlideTimer = null;
		// something asked for the keys again while they were leaving
		if (dock.hasClass('soft_kb_up')) { return; }
		dock.prop('hidden', true).attr('aria-hidden', 'true');
	}, softKbSlideMs() + 40);
}

function softKbShow(el) {
	if (!softKbOn()) { return; }
	el = softKbRoot(el);
	if (!softKbEditable(el)) { return; }
	var dock = $('#jawn_soft_keyboard');
	if (!dock.length) { return; }
	jawnMeasureHide();
	var changed = jawnSoftField !== el;
	jawnSoftField = el;
	if (softKbDesk()) { softKbStickySet(true); }
	jawnSoftNumeric = softKbNumeric(el);
	jawnSoftContext = softKbContext(el);
	if (changed) {
		jawnSoftExpr = jawnSoftNumeric ? (el.value || '') : '';
		softKbShiftSet(false);
	}
	softKbSuppress(el);
	softKbPlace(el);
	softKbSlideUp(dock);
	// the chooser is a drawer over the keys; a new field starts with it shut
	$('#soft_kb_layouts').prop('hidden', true);
	$('#soft_kb_layout_button').attr('aria-expanded', 'false').removeClass('active');
	// the search itself rises above the keys; the bar it lives in (dock or
	// taskbar) keeps whatever mode it was in
	var search_field = el.id == 'search' || $(el).closest('#search_entanglement').length > 0;
	$('body').toggleClass('soft_kb_search_field', search_field);
	$('.soft_kb_search_lifted').removeClass('soft_kb_search_lifted');
	if (search_field) { $(el).closest('#search_entanglement').addClass('soft_kb_search_lifted'); }
	$('body').addClass('soft_kb_open');
	softKbModeSet(jawnSoftNumeric ? 'calc' : 'letters');
	softKbSuggestSync();
	softKbVaultSync();
	softKbReserve();
	softKbScrollField(el);
	// the search dropdown is measured against the keyboard while the keys are up
	setTimeout(function () {
		if (typeof jawnosSearchResultsPlace === 'function') { jawnosSearchResultsPlace(); }
	}, 20);
	var chat = el.id == 'message';
	$('#chat_soft_toggle').toggleClass('active', chat).attr('aria-expanded', chat ? 'true' : 'false');
}

function softKbHide() {
	softKbMagnifyHide();
	softKbRepeatStop();
	softKbDictateStop();
	softKbStickySet(false);
	$('#soft_kb_layouts').prop('hidden', true);
	$('#soft_kb_layout_button').attr('aria-expanded', 'false').removeClass('active');
	softKbSlideDown($('#jawn_soft_keyboard'));
	$('body').removeClass('soft_kb_open soft_kb_dock_field soft_kb_bar_field soft_kb_search_field');
	$('.soft_kb_search_lifted').removeClass('soft_kb_search_lifted');
	$('.chat_shell').css('padding-bottom', '');
	$('.soft_kb_reserved').css('padding-bottom', '').removeClass('soft_kb_reserved');
	softKbConvertHide();
	$('#soft_kb_suggest').prop('hidden', true);
	softKbVaultClose();
	jawnVault.matches = [];
	jawnVault.locked = false;
	jawnVault.sheet = null;
	softKbVaultButtons();
	jawnSoftContext = '';
	jawnSoftField = null;
	if (typeof jawnosSearchResultsPlace === 'function') { setTimeout(jawnosSearchResultsPlace, 0); }
	$('#chat_soft_toggle').removeClass('active').attr('aria-expanded', 'false');
}

function softKbVisible() {
	return $('#jawn_soft_keyboard').is(':visible');
}

// The dock holds the input on a desk until another field claims it or it is
// put away. The stylesheet uses the class to keep the dock over any top-level
// window while it owns the keys.
function softKbStickySet(on) {
	jawnSoftSticky = !!on;
	$('#jawn_soft_keyboard').toggleClass('soft_kb_sticky', jawnSoftSticky);
}

// A window re-render replaces the field's element; keep the caret in the same
// field by finding its replacement by id rather than typing into a detached
// node (which looked like the keys had stopped working).
function softKbLiveField() {
	if (!jawnSoftField) { return null; }
	if (document.contains(jawnSoftField)) { return jawnSoftField; }
	var id = jawnSoftField.id;
	var found = id ? document.getElementById(id) : null;
	jawnSoftField = (found && softKbEditable(found)) ? found : null;
	return jawnSoftField;
}

function softKbPlace(el) {
	var dock = $('#jawn_soft_keyboard');
	// The dock always lives in the body: a window that re-renders or closes
	// cannot take the keyboard with it.
	if (!dock.parent().is('body')) { $('body').append(dock); }
	dock.removeClass('soft_kb_in_window soft_kb_inline');
}

// How far the search box and the dropdown must stay off the foot of the page:
// the keyboard's own top edge. A bottom anchor makes that its height, but a
// panned page or a system bar can put the edge elsewhere, and the person sees
// the edge, not the box. While the dock is sliding its transformed box still
// starts off the screen, so its height is the honest answer then.
function softKbLift(dock) {
	dock = (dock && dock.length) ? dock : $('#jawn_soft_keyboard');
	var h = dock.outerHeight() || 0;
	var vh = window.innerHeight || $(window).height();
	var settling = (Date.now() - jawnSoftSlideAt) < (softKbSlideMs() + 40);
	if (!settling && dock[0] && dock[0].getBoundingClientRect) {
		var top = dock[0].getBoundingClientRect().top;
		if (top > 0 && top < vh) { return Math.round(vh - top); }
	}
	return Math.round(h);
}

// Keep the field's own scrolling area above the keys: the Chat shell gives up
// the overlap at its foot, and an appointment (or any other window) gives it up
// in its scroll area, so its lower fields and buttons stay reachable. The window
// itself keeps its shape.
function softKbReserve() {
	$('.chat_shell').css('padding-bottom', '');
	$('.soft_kb_reserved').css('padding-bottom', '').removeClass('soft_kb_reserved');
	var dock = $('#jawn_soft_keyboard');
	if (!dock.is(':visible') || !jawnSoftField) { return; }
	// the dock and taskbar rules lift themselves by this much
	var lift = softKbLift(dock);
	if (document.body && document.body.style) {
		document.body.style.setProperty('--soft_kb_h', lift + 'px');
	}
	// the search dropdown lives in the space above the keys, and the keys just
	// changed height
	if (typeof jawnosSearchResultsPlace === 'function') { jawnosSearchResultsPlace(); }
	var chat = $(jawnSoftField).closest('.chat_shell');
	var scroller = chat.length ? chat : $(jawnSoftField).closest('.appointment_contents, .window_contents');
	if (!scroller.length) { return; }
	if (!chat.length && !scroller.closest('.wind').length) { return; }
	// the keyboard's own top edge, not just its height
	var dockTop = window.innerHeight - lift;
	var box = scroller[0].getBoundingClientRect();
	var bottom = Math.min(box.bottom, window.innerHeight);
	var overlap = Math.max(0, bottom - dockTop);
	if (overlap <= 0) { return; }
	if (chat.length) { chat.css('padding-bottom', overlap + 'px'); }
	else { scroller.addClass('soft_kb_reserved').css('padding-bottom', overlap + 'px'); }
}

