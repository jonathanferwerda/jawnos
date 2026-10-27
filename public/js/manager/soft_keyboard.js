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
}

function softKbOn() {
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
	$('#soft_kb_layouts').prop('hidden', true);
	$('#soft_kb_layout_button').attr('aria-expanded', 'false').removeClass('active');
	softKbSlideDown($('#jawn_soft_keyboard'));
	$('body').removeClass('soft_kb_open soft_kb_dock_field soft_kb_bar_field soft_kb_search_field');
	$('.soft_kb_search_lifted').removeClass('soft_kb_search_lifted');
	$('.chat_shell').css('padding-bottom', '');
	$('.soft_kb_reserved').css('padding-bottom', '').removeClass('soft_kb_reserved');
	softKbConvertHide();
	$('#soft_kb_suggest').prop('hidden', true);
	jawnSoftContext = '';
	jawnSoftField = null;
	if (typeof jawnosSearchResultsPlace === 'function') { setTimeout(jawnosSearchResultsPlace, 0); }
	$('#chat_soft_toggle').removeClass('active').attr('aria-expanded', 'false');
}

function softKbVisible() {
	return $('#jawn_soft_keyboard').is(':visible');
}

function softKbPlace(el) {
	var dock = $('#jawn_soft_keyboard');
	// The dock always lives in the body: a window that re-renders or closes
	// cannot take the keyboard with it.
	if (!dock.parent().is('body')) { $('body').append(dock); }
	dock.removeClass('soft_kb_in_window soft_kb_inline');
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
	if (document.body && document.body.style) {
		document.body.style.setProperty('--soft_kb_h', (dock.outerHeight() || 0) + 'px');
	}
	// the search dropdown lives in the space above the keys, and the keys just
	// changed height
	if (typeof jawnosSearchResultsPlace === 'function') { jawnosSearchResultsPlace(); }
	var chat = $(jawnSoftField).closest('.chat_shell');
	var scroller = chat.length ? chat : $(jawnSoftField).closest('.appointment_contents, .window_contents');
	if (!scroller.length) { return; }
	if (!chat.length && !scroller.closest('.wind').length) { return; }
	// the dock rides the screen foot and slides, so its box is measured from
	// its height rather than its (still transformed) top edge
	var dockTop = window.innerHeight - (dock.outerHeight() || 0);
	var box = scroller[0].getBoundingClientRect();
	var bottom = Math.min(box.bottom, window.innerHeight);
	var overlap = Math.max(0, bottom - dockTop);
	if (overlap <= 0) { return; }
	if (chat.length) { chat.css('padding-bottom', overlap + 'px'); }
	else { scroller.addClass('soft_kb_reserved').css('padding-bottom', overlap + 'px'); }
}

function softKbScrollField(el) {
	if (!el) { return; }
	if (el.id == 'message' && $(el).closest('.chat_shell').length) { return; }
	setTimeout(function () {
		var dock = $('#jawn_soft_keyboard');
		if (!dock.is(':visible')) { return; }
		var h = dock.outerHeight() || 0;
		el.style.scrollMarginBottom = (h + 18) + 'px';
		el.style.scrollMarginTop = '18px';
		try { el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' }); }
		catch (err) { el.scrollIntoView(); }
	}, 30);
}

function softKbTitleUpdate() {
	var dock = $('#jawn_soft_keyboard');
	var mode = jawnSoftMode;
	var title = mode == 'calc' ? softKbLabel('Calculator')
		: (mode == 'symbols' ? softKbLabel('Special characters')
		: (jawnSoftField ? softKbLayout().name : softKbLabel('Tap a field to type')));
	dock.find('.soft_kb_title').text(title);
}

function softKbModeSet(mode) {
	softKbMagnifyHide();
	if (jawnSoftNumeric && mode == 'letters') { mode = 'calc'; }
	jawnSoftMode = mode;
	var dock = $('#jawn_soft_keyboard');
	dock.find('.soft_kb_mode').removeClass('active').filter('[data-kb_mode="' + mode + '"]').addClass('active');
	dock.find('.soft_kb_panel').prop('hidden', true).filter('[data-kb_panel="' + mode + '"]').prop('hidden', false);
	dock.find('.soft_kb_mode[data-kb_mode="letters"]').prop('hidden', jawnSoftNumeric);
	if (mode == 'letters') { softKbLayoutRender(); }
	if (!jawnSoftListening) { softKbTitleUpdate(); }
	if (mode == 'calc') { softKbCalcRender(); softKbHistoryRender(); }
	softKbConvertUpdate();
	softKbReserve();
	if (jawnSoftField) { softKbScrollField(jawnSoftField); }
}

function softKbShiftSet(on) {
	jawnSoftShift = !!on;
	softKbLayoutRender();
}

// ---- dictation -------------------------------------------------------------
// The microphone beside the hide key records a phrase and hands the audio to
// the house's own transcription: whisper.cpp on this machine, or the cloud
// model chosen for the transcription role. A phrase ends by itself when the
// room falls quiet, and the next recording starts at once so talking continues
// while the last phrase is transcribed. The Guide's model then restores
// punctuation without changing a word. Nothing goes to a browser or phone
// speech service.
var JAWN_DICTATE_SILENCE = 850;
var JAWN_DICTATE_MAX = 20000;
// ---- reading the room -------------------------------------------------------
// A laptop fan or a steady hiss sits above any fixed number that reads as
// silence, so a fixed threshold never hears the pause and a phrase runs to its
// cap. Instead the room is read from the microphone itself: a fan or a hiss is
// steady, a voice is not, so a short window that wobbles is speech and the
// room already known is kept. The floor that window yields is what a phrase is
// measured against - the pause sits a margin above it, and speech has to clear
// a wider margin to start, so the room's own jitter does not read as a word.
// The keyboard's dictation and the Guide's spoken conversation share this one
// reader, so both hear the same room the same way.
var JAWN_ROOM_FALLBACK = 0.02; // until a room has been read
var JAWN_ROOM_MARGIN = 0.015;  // the pause sits at least this far above the room
var JAWN_ROOM_SCALE = 0.5;     // ... and half the room's own level, so a loud room scales
var JAWN_ROOM_ONSET_SCALE = 1.5; // speech clears a wider margin than the pause
var JAWN_ROOM_ONSET_FRAMES = 3;  // loud ticks before a phrase is taken to have begun
var JAWN_ROOM_READ_FRAMES = 5;   // the room is read over half a second at a phrase's start
var JAWN_ROOM_CV = 0.4;          // a window spread above this is speech, not the room
var JAWN_ROOM_PEAK_RATIO = 3.5;  // a pause is this far under the phrase's own peak
var JAWN_ROOM_LEARN_RATIO = 2.5; // a window this much louder than the room is speech
var jawnRoom = { floor: 0 };

var jawnDictate = {
	stream: null,
	audio: null,
	analyser: null,
	data: null,
	recorder: null,
	meter: null,
	maxTimer: null,
	target: null,
	lang: 'auto',
	segments: [],
	sending: false,
	session: 0
};

var jawnDictateFieldButton = null;

function softKbDictateHint(text) {
	$('#jawn_soft_keyboard .soft_kb_title').text(text || '');
	// a rich editor's microphone is not in the dock, so the state it shows has to
	// travel to the button that started it
	$('.text_editor_container .text_editor_dictate').each(function () {
		var box = $(this).closest('.text_editor_container').find('.text_editor')[0];
		if (box && jawnDictate.target === box) { $(this).attr('title', text || ''); }
	});
	if (!jawnDictate.target && jawnDictateFieldButton && jawnDictateFieldButton.length) {
		jawnDictateFieldButton.attr('title', text || '');
	}
	// with the dock closed there is no title to read, so a failure has to be said
	// out loud; the progress words are not failures
	var progress = (text == softKbLabel('Listening…') || text == softKbLabel('Transcribing…') || !text);
	if (!progress && !softKbVisible() && typeof jawnosAlert === 'function') { jawnosAlert(text); }
}

function softKbDictateErrorText(code) {
	if (code == 'no-audio') { return softKbLabel('I did not catch any audio'); }
	if (code == 'unreadable') { return softKbLabel('I could not make out any words'); }
	if (code == 'no-model') { return softKbLabel('No transcription is set up on this machine'); }
	if (code == 'words') { return softKbLabel('I could not punctuate that'); }
	return softKbLabel('I could not transcribe that');
}

function softKbMicState() {
	var on = !!jawnSoftListening;
	$('#soft_kb_mic_button')
		.toggleClass('active soft_kb_mic_listening', on)
		.attr('aria-pressed', on ? 'true' : 'false')
		.attr('aria-label', softKbLabel(on ? 'Stop dictation' : 'Start dictation'))
		.attr('hint', softKbLabel(on ? 'Stop dictation' : 'Start dictation'));
	// the same dictation can be started from a rich text editor's toolbox
	$('.text_editor_container .text_editor_dictate').each(function () {
		var btn = $(this);
		var box = btn.closest('.text_editor_container').find('.text_editor')[0];
		var live = on && jawnDictate.target && box === jawnDictate.target;
		btn.toggleClass('active', !!live).attr('aria-pressed', live ? 'true' : 'false');
		btn.attr('aria-label', softKbLabel(live ? 'Stop dictation' : 'Start dictation'));
	});
}

// The level a phrase must cross to start (onset) or fall back under to end
// (quiet): the room's own level plus a margin.
function jawnRoomThreshold(onset) {
	var floor = jawnRoom.floor || JAWN_ROOM_FALLBACK;
	var margin = floor * JAWN_ROOM_SCALE;
	if (margin < JAWN_ROOM_MARGIN) { margin = JAWN_ROOM_MARGIN; }
	if (onset) { margin *= JAWN_ROOM_ONSET_SCALE; }
	return floor + margin;
}

// The room's own level from a short window of ticks: its mean when the window is
// steady, or null when it wobbles like a voice. The spread is taken from the
// same window, so a quiet room's floor is not thrown by a little jitter.
function jawnRoomRead(win) {
	var n = win.length, sum = 0, i;
	for (i = 0; i < n; i++) { sum += win[i]; }
	var mean = sum / n;
	if (!mean) { return 0; }
	var spread = 0;
	for (i = 0; i < n; i++) { var d = win[i] - mean; spread += d * d; }
	if (Math.sqrt(spread / n) / mean > JAWN_ROOM_CV) { return null; }
	return mean;
}

// Learn the room from a read window. With no room yet, a steady window is the
// room; a wobbling window is taken at its median for a conversation (whose
// first window, just after Converse is pressed, is clean) and at its quietest
// tick for dictation (whose first phrase may already contain speech). Once a
// room is known, a window only replaces it when it is not much louder: a voice,
// or the guide's own reply, must not drag the floor up.
function jawnRoomLearn(win, trust_wobble) {
	var n = win.length, i, sum = 0;
	for (i = 0; i < n; i++) { sum += win[i]; }
	var mean = sum / n;
	if (!jawnRoom.floor) {
		var steady = jawnRoomRead(win);
		if (steady != null && steady > 0) { jawnRoom.floor = steady; return; }
		var pick;
		if (trust_wobble) {
			var sorted = win.slice().sort(function (a, b) { return a - b; });
			pick = sorted[Math.floor(sorted.length / 2)];
		}
		else {
			pick = win[0];
			for (i = 1; i < n; i++) { if (win[i] < pick) { pick = win[i]; } }
		}
		jawnRoom.floor = pick || 0;
		return;
	}
	if (mean > 0 && mean <= jawnRoom.floor * JAWN_ROOM_LEARN_RATIO) { jawnRoom.floor = mean; }
}

// A new session reads its own room: the machine may have been carried
// somewhere louder since the last one.
function jawnRoomReset() { jawnRoom.floor = 0; }

function softKbDictateCut() {
	if (jawnDictate.meter) { clearInterval(jawnDictate.meter); jawnDictate.meter = null; }
	if (jawnDictate.maxTimer) { clearTimeout(jawnDictate.maxTimer); jawnDictate.maxTimer = null; }
	var rec = jawnDictate.recorder;
	jawnDictate.recorder = null;
	if (rec && rec.state != 'inactive') { try { rec.stop(); } catch (err) {} }
}

function softKbDictateRelease() {
	if (jawnDictate.stream) {
		jawnDictate.stream.getTracks().forEach(function (t) { try { t.stop(); } catch (err) {} });
		jawnDictate.stream = null;
	}
	if (jawnDictate.audio) {
		try { jawnDictate.audio.close(); } catch (err) {}
		jawnDictate.audio = null;
	}
	jawnDictate.analyser = null;
	jawnDictate.data = null;
}

function softKbDictateStop() {
	jawnSoftListening = false;
	jawnDictate.session++;
	softKbDictateCut();
	softKbDictateRelease();
	jawnDictate.target = null;
	softKbMicState();
	if (!jawnDictate.sending && !jawnDictate.segments.length) { softKbTitleUpdate(); }
}

function softKbDictateUnavailable() {
	jawnSoftListening = false;
	jawnDictate.session++;
	softKbDictateCut();
	softKbDictateRelease();
	softKbMicState();
	softKbDictateHint(softKbLabel('Dictation is not available in this browser'));
}

function softKbDictateMime() {
	if (!window.MediaRecorder || !MediaRecorder.isTypeSupported) { return ''; }
	var types = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/mp4'];
	try {
		for (var i = 0; i < types.length; i++) {
			if (MediaRecorder.isTypeSupported(types[i])) { return types[i]; }
		}
	}
	catch (err) { return ''; }
	return '';
}

// One phrase. The recorder is replaced only after the last one has really
// stopped, so a phrase can never be captured twice by two live recorders.
function softKbDictateSegment() {
	if (!jawnSoftListening || !jawnDictate.stream || jawnDictate.recorder) { return; }
	var mime = softKbDictateMime();
	var rec;
	try {
		rec = mime ? new MediaRecorder(jawnDictate.stream, { mimeType: mime }) : new MediaRecorder(jawnDictate.stream);
	}
	catch (err) {
		try { rec = new MediaRecorder(jawnDictate.stream); }
		catch (err2) { softKbDictateUnavailable(); return; }
	}
	var seg = { chunks: [], heard: false, run: 0, quiet: 0, peak: 0, read: JAWN_ROOM_READ_FRAMES, win: [], target: jawnDictate.target, mime: mime || rec.mimeType || 'audio/webm' };
	jawnDictate.recorder = rec;
	rec.ondataavailable = function (e) { if (e.data && e.data.size) { seg.chunks.push(e.data); } };
	rec.onstop = function () {
		if (jawnDictate.recorder === rec) { jawnDictate.recorder = null; }
		if (seg.heard && seg.chunks.length) {
			var blob = new Blob(seg.chunks, { type: seg.mime });
			if (blob.size > 1200) {
				jawnDictate.segments.push({ blob: blob, target: seg.target });
				softKbDictateQueue();
			}
		}
		if (jawnSoftListening) { setTimeout(function () { softKbDictateSegment(); }, 0); }
	};
	try { rec.start(250); }
	catch (err) { jawnDictate.recorder = null; softKbDictateUnavailable(); return; }
	if (jawnDictate.analyser) {
		jawnDictate.meter = setInterval(function () {
			if (!jawnDictate.analyser) { return; }
			jawnDictate.analyser.getByteTimeDomainData(jawnDictate.data);
			var rms = 0;
			for (var i = 0; i < jawnDictate.data.length; i++) {
				var d = (jawnDictate.data[i] - 128) / 128;
				rms += d * d;
			}
			rms = Math.sqrt(rms / jawnDictate.data.length);
			// a phrase opens by reading the room, before any of it is judged. The
			// audio is already being recorded, so nothing said in this moment is lost.
			if (seg.read > 0) {
				seg.win.push(rms);
				if (--seg.read === 0) { jawnRoomLearn(seg.win); }
				return;
			}
			var loud = (rms > jawnRoomThreshold(true));
			var quiet = (rms <= jawnRoomThreshold(false));
			if (!seg.heard) {
				// one loud tick is the room or a tap, so speech has to hold before the
				// phrase is taken to have started
				if (!loud) { seg.run = 0; return; }
				if (++seg.run < JAWN_ROOM_ONSET_FRAMES) { return; }
				seg.heard = true;
				seg.run = 0;
				seg.quiet = 0;
				seg.peak = rms;
				return;
			}
			// the pause is measured against the room read before the phrase, and
			// against the phrase's own peak when that room reads high or low
			if (rms > seg.peak) { seg.peak = rms; }
			var hushed = (seg.peak > JAWN_ROOM_FALLBACK && rms * JAWN_ROOM_PEAK_RATIO < seg.peak);
			if (!quiet && !hushed) { seg.quiet = 0; return; }
			if (!seg.quiet) { seg.quiet = Date.now(); return; }
			if (Date.now() - seg.quiet > JAWN_DICTATE_SILENCE) { softKbDictateFinishSegment(rec); }
		}, 100);
	}
	jawnDictate.maxTimer = setTimeout(function () { softKbDictateFinishSegment(rec); }, JAWN_DICTATE_MAX);
}

function softKbDictateFinishSegment(rec) {
	if (!rec || rec.state == 'inactive') { return; }
	if (jawnDictate.meter) { clearInterval(jawnDictate.meter); jawnDictate.meter = null; }
	if (jawnDictate.maxTimer) { clearTimeout(jawnDictate.maxTimer); jawnDictate.maxTimer = null; }
	try { rec.stop(); } catch (err) {}
}

// Transcribe the finished phrases in the order they were spoken, while the next
// one is already being recorded.
function softKbDictateQueue() {
	if (jawnDictate.sending) { return; }
	var item = jawnDictate.segments.shift();
	if (!item) {
		if (jawnSoftListening) { softKbDictateHint(softKbLabel('Listening…')); }
		else { softKbTitleUpdate(); }
		return;
	}
	jawnDictate.sending = true;
	if (!jawnSoftListening) { softKbDictateHint(softKbLabel('Transcribing…')); }
	$.ajax({
		url: '/manager/dictate?lang=' + encodeURIComponent(jawnDictate.lang || 'auto'),
		type: 'POST',
		data: item.blob,
		processData: false,
		contentType: 'application/octet-stream',
		dataType: 'json',
		timeout: 120000,
		success: function (r) {
			jawnDictate.sending = false;
			if (r && r.text) {
				softKbDictationAppend(item.target, r.text);
				if (jawnSoftListening) { softKbDictateHint(softKbLabel('Listening…')); }
			}
			else if (r && r.error) { softKbDictateHint(softKbDictateErrorText(r.error)); }
			softKbDictateQueue();
		},
		error: function () {
			jawnDictate.sending = false;
			softKbDictateHint(softKbLabel('I could not transcribe that'));
			softKbDictateQueue();
		}
	});
}

// A dictation phrase joins the field where the microphone was opened, even if
// the person has moved on to another window while it was being transcribed.
function softKbDictationAppend(target, text) {
	if (!target || !document.contains(target) || !softKbEditable(target)) { return; }
	text = String(text || '').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
	if (!text) { return; }
	var sep = '';
	if (!target.isContentEditable) {
		var caret = (target.selectionStart == null) ? (target.value || '').length : target.selectionStart;
		var before = (target.value || '').charAt(caret - 1);
		if (caret > 0 && before && !/\s/.test(before) && !/^[,.;:!?)]/.test(text)) { sep = ' '; }
	}
	else {
		var last = (target.textContent || '').slice(-1);
		if (last && !/\s/.test(last) && !/^[,.;:!?)]/.test(text)) { sep = ' '; }
	}
	softKbInsert(sep + text, target, true);
}

function softKbDictateToggle() {
	if (jawnSoftListening) { softKbDictateStop(); return; }
	if (!jawnSoftField) { softKbDictateHint(softKbLabel('Tap a field first')); return; }
	if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || !window.MediaRecorder) {
		softKbDictateUnavailable();
		return;
	}
	softKbLayoutsToggle(false);
	jawnSoftListening = true;
	var session = ++jawnDictate.session;
	jawnDictate.target = jawnSoftField;
	jawnDictate.lang = String(softKbLayout().lang || 'auto').split('-')[0];
	softKbMicState();
	softKbDictateHint(softKbLabel('Listening…'));
	// the conversation's capture settings, so the one room floor both readers
	// share is measured on signals processed the same way
	var dictate_mic = navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: false, autoGainControl: false } }).catch(function () {
		return navigator.mediaDevices.getUserMedia({ audio: true });
	});
	dictate_mic.then(function (stream) {
		if (!jawnSoftListening || session != jawnDictate.session) {
			stream.getTracks().forEach(function (t) { try { t.stop(); } catch (err) {} });
			return;
		}
		jawnDictate.stream = stream;
		// a session reads its own room: the machine may have been carried somewhere
		// louder since the last one
		jawnRoomReset();
		try {
			jawnDictate.audio = new (window.AudioContext || window.webkitAudioContext)();
			var src = jawnDictate.audio.createMediaStreamSource(stream);
			// the same high pass the Guide's conversation uses: a fan's low rumble
			// must not be the room either side of the shared floor
			var hp = jawnDictate.audio.createBiquadFilter();
			hp.type = 'highpass';
			hp.frequency.value = 180;
			src.connect(hp);
			jawnDictate.analyser = jawnDictate.audio.createAnalyser();
			jawnDictate.analyser.fftSize = 1024;
			jawnDictate.data = new Uint8Array(jawnDictate.analyser.fftSize);
			hp.connect(jawnDictate.analyser);
		}
		catch (err) { jawnDictate.analyser = null; jawnDictate.data = null; }
		softKbDictateSegment();
	}).catch(function () {
		if (session != jawnDictate.session) { return; }
		jawnSoftListening = false;
		softKbMicState();
		softKbDictateHint(softKbLabel('I could not reach the microphone'));
	});
}

// Dictation aimed at a rich text editor's contenteditable, from the microphone
// in its toolbox. It is the dock's own dictation: the editor becomes the field
// being typed in, and each phrase joins the words where the caret is.
function softKbDictateField(el) {
	if (!el) { return; }
	if (jawnSoftListening) { softKbDictateStop(); return; }
	jawnSoftField = el;
	jawnSoftNumeric = false;
	jawnSoftContext = softKbContext(el);
	jawnDictateFieldButton = $(el).closest('.text_editor_container').find('.text_editor_dictate');
	softKbDictateToggle();
}

$(document).on('pointerdown', '.text_editor_dictate', function (e) {
	if (e.button != null && e.button != 0) { return; }
	// keep the caret in the words: a focused button would make the phrase append
	e.preventDefault();
});

$(document).on('click', '.text_editor_dictate', function (e) {
	e.preventDefault();
	var box = $(this).closest('.text_editor_container').find('.text_editor')[0];
	if (box) { softKbDictateField(box); }
});

function softKbNotify(el) {
	if (!el) { return; }
	var fire = function () {
		$(el).trigger('input');
		// older fields listen on keyup rather than input (the search box, the
		// text editor); a harmless space code keeps their handlers in step
		$(el).trigger($.Event('keyup', { key: ' ', keyCode: 32 }));
		if (!el.isContentEditable) { return; }
		// The house's rich text editor keeps a source textarea beside its
		// contenteditable; copy the words across so the app's own save sees them.
		var source = el.getAttribute('source_id');
		if (source && $('#' + source).length) {
			$('#' + source).val($(el).text());
			$('#' + source).trigger('change');
		}
	};
	if (window.requestAnimationFrame) { requestAnimationFrame(fire); }
	else { setTimeout(fire, 0); }
	// A dictation phrase can arrive for a field that is no longer the one being
	// typed in; only the current field's conversion and suggestion rows follow it.
	if (el === jawnSoftField) {
		softKbConvertUpdate();
		softKbSuggestSync();
	}
}

function softKbInsert(text, target, nofocus) {
	var el = target || jawnSoftField;
	if (!el) { return; }
	if (el.isContentEditable) {
		// A transcribed phrase for a field that is no longer focused appends to
		// its end; focusing it would take the caret away from where the person is.
		if (document.activeElement !== el) {
			if (nofocus) {
				try { el.appendChild(document.createTextNode(text)); }
				catch (err) {}
				softKbNotify(el);
				return;
			}
		}
		el.focus({ preventScroll: true });
		var ok = false;
		try {
			ok = (text == '\n')
				? document.execCommand('insertHTML', false, '<br>')
				: document.execCommand('insertText', false, text);
		} catch (err) { ok = false; }
		if (!ok) {
			var sel = window.getSelection();
			if (sel && sel.rangeCount) {
				var range = sel.getRangeAt(0);
				range.deleteContents();
				var node = document.createTextNode(text);
				range.insertNode(node);
				range.setStartAfter(node);
				range.collapse(true);
				sel.removeAllRanges();
				sel.addRange(range);
			}
		}
		softKbNotify(el);
		return;
	}
	var start = (el.selectionStart == null) ? el.value.length : el.selectionStart;
	var end = (el.selectionEnd == null) ? start : el.selectionEnd;
	try { el.setRangeText(text, start, end, 'end'); }
	catch (err) {
		el.value = el.value.slice(0, start) + text + el.value.slice(end);
		el.selectionStart = el.selectionEnd = start + text.length;
	}
	if (!nofocus) { try { el.focus({ preventScroll: true }); } catch (err2) { el.focus(); } }
	softKbNotify(el);
}

function softKbBackspace() {
	var el = jawnSoftField;
	if (!el) { return; }
	if (el.isContentEditable) {
		el.focus({ preventScroll: true });
		try { document.execCommand('delete'); } catch (err) {}
		softKbNotify(el);
		return;
	}
	var start = (el.selectionStart == null) ? el.value.length : el.selectionStart;
	var end = (el.selectionEnd == null) ? start : el.selectionEnd;
	if (start == end) {
		if (start == 0) { return; }
		var code = el.value.charCodeAt(start - 1);
		if (code >= 0xDC00 && code <= 0xDFFF && start >= 2) {
			var high = el.value.charCodeAt(start - 2);
			start = (high >= 0xD800 && high <= 0xDBFF) ? start - 2 : start - 1;
		}
		else { start--; }
	}
	try { el.setRangeText('', start, end, 'end'); }
	catch (err) {
		el.value = el.value.slice(0, start) + el.value.slice(end);
		el.selectionStart = el.selectionEnd = start;
	}
	try { el.focus({ preventScroll: true }); } catch (err2) { el.focus(); }
	softKbNotify(el);
}

// ---- hold-to-repeat ---------------------------------------------------------
// A held backspace repeats characters, starting after a short wait and getting
// faster the longer it is held. A double tap takes a whole word at once, and
// holding after it keeps taking words the same way. The calculator has no
// words, so it always repeats its expression one character at a time.
var JAWN_SOFT_HOLD_DELAY = 450;
var JAWN_SOFT_CHAR_FIRST = 140;
var JAWN_SOFT_CHAR_MIN = 30;
var JAWN_SOFT_WORD_FIRST = 220;
var JAWN_SOFT_WORD_MIN = 90;
var JAWN_SOFT_ACCEL = 0.82;
var JAWN_SOFT_DOUBLE = 380;
var jawnSoftHold = null;
var jawnSoftHoldAt = 0;
var jawnSoftBackspaceAt = 0;

function softKbDeleteSpan(el, start, end) {
	if (!el || start == null || end == null || start >= end) { return; }
	try { el.setRangeText('', start, end, 'end'); }
	catch (err) {
		el.value = el.value.slice(0, start) + el.value.slice(end);
		el.selectionStart = el.selectionEnd = start;
	}
	try { el.focus({ preventScroll: true }); } catch (err2) { el.focus(); }
	softKbNotify(el);
}

// backward to the start of the previous word, trailing spaces included
function softKbDeleteWord() {
	var el = jawnSoftField;
	if (!el) { return; }
	if (el.isContentEditable) { softKbDeleteGranularity('word'); return; }
	var v = el.value || '';
	var end = (el.selectionStart == null) ? v.length : el.selectionStart;
	var start = (el.selectionEnd == null) ? end : el.selectionEnd;
	if (start != end) { softKbDeleteSpan(el, start, end); return; }
	var i = end;
	while (i > 0 && /\s/.test(v.charAt(i - 1))) { i--; }
	while (i > 0 && !/\s/.test(v.charAt(i - 1))) { i--; }
	softKbDeleteSpan(el, i, end);
}

// contenteditable: let the selection walk back by a word, then delete
function softKbDeleteGranularity(gran) {
	var el = jawnSoftField;
	if (!el) { return; }
	try { el.focus({ preventScroll: true }); } catch (err) {}
	var sel = window.getSelection ? window.getSelection() : null;
	if (sel && sel.rangeCount) {
		try { sel.modify('extend', 'backward', gran); }
		catch (err2) { sel = null; }
		if (sel) {
			try { document.execCommand('delete'); } catch (err3) {}
			softKbNotify(el);
			return;
		}
	}
	try { document.execCommand('delete'); } catch (err4) {}
	softKbNotify(el);
}

function softKbRepeatStop() {
	if (!jawnSoftHold) { return; }
	clearTimeout(jawnSoftHold.timer);
	jawnSoftHold = null;
	jawnSoftHoldAt = Date.now();
}

function softKbRepeatBegin() {
	var hold = jawnSoftHold;
	if (!hold) { return; }
	if (!jawnSoftField) { softKbRepeatStop(); return; }
	if (hold.mode == 'calc') {
		softKbRepeatStart(hold, JAWN_SOFT_CHAR_FIRST, JAWN_SOFT_CHAR_MIN, function () { softKbCalcKey('backspace'); });
		return;
	}
	if (hold.mode == 'word') {
		softKbRepeatStart(hold, JAWN_SOFT_WORD_FIRST, JAWN_SOFT_WORD_MIN, softKbDeleteWord);
		return;
	}
	softKbRepeatStart(hold, JAWN_SOFT_CHAR_FIRST, JAWN_SOFT_CHAR_MIN, softKbBackspace);
}

// Each repeat comes a little sooner than the last, down to a floor.
function softKbRepeatStart(hold, every, min, fn) {
	hold.every = every;
	hold.min = min;
	hold.fn = fn;
	hold.timer = setTimeout(function () { softKbRepeatStep(hold); }, every);
}

function softKbRepeatStep(hold) {
	if (jawnSoftHold !== hold) { return; }
	if (!jawnSoftField) { softKbRepeatStop(); return; }
	hold.fn();
	hold.every = Math.max(hold.min, Math.round(hold.every * JAWN_SOFT_ACCEL));
	hold.timer = setTimeout(function () { softKbRepeatStep(hold); }, hold.every);
}

// The backspace press itself still deletes at once; the hold is armed behind it.
function softKbBackspaceOnce() {
	if (jawnSoftMode == 'calc') { softKbCalcKey('backspace'); }
	else { softKbBackspace(); }
}

function softKbBackspaceDown(el) {
	var now = Date.now();
	var double = (now - jawnSoftBackspaceAt) < JAWN_SOFT_DOUBLE;
	jawnSoftBackspaceAt = now;
	softKbRepeatStop();
	if (double && jawnSoftMode != 'calc') {
		// a double tap takes the whole word at once
		softKbDeleteWord();
	}
	else { softKbBackspaceOnce(); }
	if (!jawnSoftField) { return; }
	jawnSoftHold = {
		mode: (jawnSoftMode == 'calc') ? 'calc' : (double ? 'word' : 'char'),
		started: now,
		timer: null, every: 0, min: 0, fn: null
	};
	jawnSoftHold.timer = setTimeout(function () { softKbRepeatBegin(); }, JAWN_SOFT_HOLD_DELAY);
}

function softKbEnter() {
	var el = jawnSoftField;
	if (jawnSoftMode == 'calc') { softKbCalcEquals(); return; }
	if (!el) { return; }
	if (el.tagName == 'TEXTAREA' || el.isContentEditable) { softKbInsert('\n'); return; }
	$(el).trigger($.Event('keydown', { key: 'Enter', keyCode: 13, which: 13 }));
	$(el).trigger($.Event('keyup', { key: 'Enter', keyCode: 13, which: 13 }));
}

// ---- calculator ------------------------------------------------------------
function softKbCalcKey(k) {
	if (k == '=') { softKbCalcEquals(); softKbConvertUpdate(); return; }
	if (k == 'clear') { jawnSoftExpr = ''; softKbCalcRender(); softKbCalcSyncNumeric(); softKbConvertUpdate(); return; }
	if (k == 'backspace') { jawnSoftExpr = jawnSoftExpr.slice(0, -1); softKbCalcRender(); softKbCalcSyncNumeric(); softKbConvertUpdate(); return; }
	if (k == 'sign') {
		var m = jawnSoftExpr.match(/(\d*\.?\d+)$/);
		if (m) {
			var at = jawnSoftExpr.length - m[1].length;
			jawnSoftExpr = jawnSoftExpr.slice(0, at) + (m[1].charAt(0) == '-' ? m[1].slice(1) : '-' + m[1]);
			softKbCalcRender();
			softKbCalcSyncNumeric();
			softKbConvertUpdate();
		}
		return;
	}
	if (/^[0-9.]$/.test(k) || ['+', '-', '*', '/', '(', ')', '%'].indexOf(k) >= 0) {
		jawnSoftExpr += k;
		softKbCalcRender();
		softKbCalcSyncNumeric();
		softKbConvertUpdate();
	}
}

// A number field mirrors the operand currently being typed, not the whole
// expression (a number input cannot hold '+' or '('). Backspace therefore edits
// the field as well as the calculator screen.
function softKbCalcSyncNumeric() {
	if (!jawnSoftNumeric || !jawnSoftField) { return; }
	var m = jawnSoftExpr.match(/(-?\d*\.?\d*)$/);
	var value = m ? m[1] : '';
	if (value == '-' || value == '.') { value = ''; }
	if (/\.$/.test(value)) { value = value.slice(0, -1); }
	jawnSoftSetting = true;
	jawnSoftField.value = value;
	$(jawnSoftField).trigger('input');
	$(jawnSoftField).trigger($.Event('keyup', { key: ' ', keyCode: 32 }));
	jawnSoftSetting = false;
}

function softKbCalcRender() {
	$('#soft_kb_expr').text(jawnSoftExpr || '0');
	$('#soft_kb_result').text('');
}

function softKbCalcEquals() {
	var expr = jawnSoftExpr.trim();
	if (!expr) { return; }
	var value = null;
	try { value = softKbEval(expr); } catch (err) { value = null; }
	if (value == null || !isFinite(value)) {
		$('#soft_kb_result').text(softKbLabel('Error'));
		return;
	}
	var out = softKbFormat(value);
	jawnSoftExpr = out;
	$('#soft_kb_expr').text(out);
	$('#soft_kb_result').text('');
	softKbHistoryAdd(expr, out);
	if (jawnSoftNumeric && jawnSoftField) {
		jawnSoftSetting = true;
		jawnSoftField.value = out;
		try { jawnSoftField.focus({ preventScroll: true }); } catch (err) { jawnSoftField.focus(); }
		$(jawnSoftField).trigger('input');
		$(jawnSoftField).trigger('change');
		jawnSoftSetting = false;
	}
	else { softKbInsert(out); }
}

// ---- the running list of calculations and conversions ----------------------
// Kept in localStorage so the sums a person works out survive a reload. A chip
// carries the result back into the field; the newest sum sits first.
var jawnSoftHistory = null;

function softKbHistoryLoad() {
	if (jawnSoftHistory) { return jawnSoftHistory; }
	var list = [];
	try {
		var raw = localStorage.getItem('jawn_soft_calc_history');
		var parsed = raw ? JSON.parse(raw) : null;
		if (parsed && parsed.length) {
			for (var i = 0; i < parsed.length; i++) {
				var item = parsed[i];
				if (item && typeof item.expr == 'string' && typeof item.out == 'string') { list.push({ expr: item.expr, out: item.out }); }
			}
		}
	} catch (err) { list = []; }
	if (list.length > 30) { list.length = 30; }
	jawnSoftHistory = list;
	return jawnSoftHistory;
}

function softKbHistorySave() {
	try { localStorage.setItem('jawn_soft_calc_history', JSON.stringify(jawnSoftHistory || [])); } catch (err) {}
}

function softKbHistoryAdd(expr, out) {
	expr = (expr || '').trim();
	if (!expr || !out || expr == out) { return; }
	var list = softKbHistoryLoad().filter(function (item) { return item.expr != expr; });
	list.unshift({ expr: expr, out: out });
	if (list.length > 30) { list.length = 30; }
	jawnSoftHistory = list;
	softKbHistorySave();
	softKbHistoryRender();
}

function softKbHistoryRender() {
	var box = $('#soft_kb_history');
	if (!box.length) { return; }
	var list = softKbHistoryLoad();
	var wrap = $('#soft_kb_history_wrap');
	box.empty();
	if (!list.length) { wrap.prop('hidden', true); return; }
	for (var i = 0; i < list.length; i++) {
		var label = list[i].expr + ' = ' + list[i].out;
		$('<button type="button" class="soft_kb_history_item"></button>')
			.attr({ 'data-kb_history': list[i].out, title: label, 'aria-label': label })
			.text(label)
			.appendTo(box);
	}
	wrap.prop('hidden', false);
}

function softKbHistoryPick(out) {
	if (!out) { return; }
	if (jawnSoftNumeric && jawnSoftField) {
		jawnSoftExpr = out;
		softKbCalcRender();
		softKbCalcSyncNumeric();
		try { jawnSoftField.focus({ preventScroll: true }); } catch (err) {}
		return;
	}
	if (jawnSoftMode == 'calc') {
		jawnSoftExpr = out;
		softKbCalcRender();
	}
	softKbInsert(out);
}

// ---- the units a typed quantity converts to --------------------------------
// A quantity typed as "$32.31", "5jpy" or "32.33L" names its unit; every other
// unit of the same kind is offered in a row under the display. The last unit
// used is remembered, so a bare number keeps converting without typing "usd"
// again. The server answers from the same registry the old calculator used.
var jawnSoftUnit = null;
var jawnSoftUnits = null;
var jawnSoftSymbols = null;
var jawnSoftBase = null;
var jawnSoftTypes = null;
var jawnSoftType = '';
var jawnSoftUse = null;
var jawnSoftConvertTimer = null;
var jawnSoftConvertSeq = 0;
var JAWN_SOFT_CONVERT_MAX = 12;

function softKbUnitsLoad() {
	if (jawnSoftUnits) { return jawnSoftUnits; }
	jawnSoftUnits = {};
	jawnSoftSymbols = {};
	jawnSoftTypes = [];
	var el = document.getElementById('soft_kb_units');
	if (el) {
		try {
			var data = JSON.parse(el.textContent || el.innerHTML || '{}');
			jawnSoftUnits = data.units || {};
			jawnSoftSymbols = data.symbols || {};
			jawnSoftBase = data.base || null;
			jawnSoftTypes = data.types || [];
		} catch (err) {}
	}
	return jawnSoftUnits;
}

function softKbTypeLabel(key) {
	var labels = {
		currency: 'Currency', weight: 'Weight', volume: 'Volume', distance: 'Distance',
		temperature: 'Temperature', speed: 'Speed', power: 'Power', resistance: 'Resistance'
	};
	return softKbLabel(labels[key] || key);
}

// How often each target unit has been used: the row puts the most-used first.
function softKbUseLoad() {
	if (jawnSoftUse) { return jawnSoftUse; }
	jawnSoftUse = {};
	try {
		var raw = localStorage.getItem('jawn_soft_convert_use');
		var parsed = raw ? JSON.parse(raw) : null;
		if (parsed && typeof parsed == 'object') { jawnSoftUse = parsed; }
	} catch (err) { jawnSoftUse = {}; }
	return jawnSoftUse;
}

function softKbUseAdd(unit) {
	if (!unit) { return; }
	var use = softKbUseLoad();
	use[unit] = (Number(use[unit]) || 0) + 1;
	try { localStorage.setItem('jawn_soft_convert_use', JSON.stringify(use)); } catch (err) {}
}

function softKbUnitCode(raw) {
	var units = softKbUnitsLoad();
	if (!raw) { return null; }
	if (units[raw]) { return raw; }
	if (units[raw.toUpperCase()]) { return raw.toUpperCase(); }
	if (units[raw.toLowerCase()]) { return raw.toLowerCase(); }
	var low = String(raw).toLowerCase();
	for (var k in units) {
		var u = units[k] || {};
		if (u.name && String(u.name).toLowerCase() == low) { return k; }
		if (u.plural && String(u.plural).toLowerCase() == low) { return k; }
	}
	if (low.length > 3 && /s$/.test(low)) { return softKbUnitCode(low.slice(0, -1)); }
	return null;
}

function softKbNumber(text) {
	var n = parseFloat(String(text || '').replace(/,/g, ''));
	return isFinite(n) ? n : null;
}

// The last quantity in the text: a number followed by a code, or a currency
// symbol followed by a number. A bare number falls back to the remembered unit
// only in the calculator, so composing a message is not turned into money. The
// desk's row passes `strict` so a bare number in an ordinary field is left be.
function softKbConvertParse(text, strict) {
	softKbUnitsLoad();
	text = String(text || '');
	var best = null;
	// a space between the number and its unit is ordinary prose ("32.33 L"), and
	// a unit's own name can be longer than its code ("kilograms")
	var re = /(-?\d[\d,]*(?:\.\d+)?)\s*([A-Za-z]{1,12})/g;
	var m;
	while ((m = re.exec(text))) {
		if (/[A-Za-z]/.test(text.charAt(re.lastIndex))) { continue; }
		var code = softKbUnitCode(m[2]);
		var value = softKbNumber(m[1]);
		if (!code || value == null) { continue; }
		best = { value: value, unit: code, at: m.index, len: m[0].length };
	}
	var sre = /([$\u20ac\u00a3\u00a5\u20b9\u20bd\u20a9\u20ba\u20bf\u039e\u20b3\u0141\u00d0\u25ce])\s*(-?\d[\d,]*(?:\.\d+)?)/g;
	while ((m = sre.exec(text))) {
		var sym = (jawnSoftSymbols || {})[m[1]];
		var v = softKbNumber(m[2]);
		if (!sym || v == null) { continue; }
		if (!best || m.index >= best.at) { best = { value: v, unit: sym, at: m.index, len: m[0].length }; }
	}
	if (best) { return best; }
	if (!strict && jawnSoftMode == 'calc' && jawnSoftUnit) {
		var tm = text.match(/(-?\d[\d,]*(?:\.\d+)?)\s*$/);
		if (tm) {
			var n = softKbNumber(tm[1]);
			if (n != null) { return { value: n, unit: jawnSoftUnit, at: tm.index, len: tm[0].length, sticky: true }; }
		}
	}
	return null;
}

function softKbConvertText() {
	var el = jawnSoftField;
	if (el && (el.getAttribute('type') || '').toLowerCase() == 'password') { return ''; }
	if (jawnSoftMode == 'calc') { return jawnSoftExpr || ''; }
	if (!el) { return ''; }
	return el.isContentEditable ? $(el).text() : (el.value || '');
}

function softKbConvertHide() {
	clearTimeout(jawnSoftConvertTimer);
	jawnSoftConvertSeq++;
	var wrap = $('#soft_kb_convert');
	var types = $('#soft_kb_types');
	var shown = false;
	if (wrap.length && !wrap.prop('hidden')) { wrap.prop('hidden', true); shown = true; }
	if (types.length && !types.prop('hidden')) { types.prop('hidden', true); shown = true; }
	if (shown) { softKbReserve(); }
}

function softKbConvertUpdate() {
	if (!$('#jawn_soft_keyboard').is(':visible')) { return; }
	// a time, a length, a warranty or a repeat already names its own units;
	// "5m" there is five minutes and must not be read as metres
	if (jawnSoftContext == 'when' || jawnSoftContext == 'duration' || jawnSoftContext == 'warranty' || jawnSoftContext == 'schedule' || jawnSoftContext == 'password') {
		softKbConvertHide();
		return;
	}
	var hit = softKbConvertParse(softKbConvertText());
	if (!hit) { softKbConvertHide(); return; }
	jawnSoftUnit = hit.unit;
	try { localStorage.setItem('jawn_soft_calc_unit', hit.unit); } catch (err) {}
	var seq = ++jawnSoftConvertSeq;
	clearTimeout(jawnSoftConvertTimer);
	jawnSoftConvertTimer = setTimeout(function () {
		$.get('/manager/keyboard/convert', { unit: hit.unit, value: hit.value }, function (r) {
			if (seq != jawnSoftConvertSeq) { return; }
			if (!r || !r.ok || !r.rows || !r.rows.length) { softKbConvertHide(); return; }
			softKbConvertRender(r);
		}, 'json').fail(function () {
			if (seq == jawnSoftConvertSeq) { softKbConvertHide(); }
		});
	}, 260);
}

function softKbConvertRender(r) {
	var wrap = $('#soft_kb_convert');
	if (!wrap.length) { return; }
	softKbUnitsLoad();
	jawnSoftType = r.type ? (r.type == 'mass' ? 'weight' : r.type) : jawnSoftType;
	// the kinds of measure, the active one wearing the highlight
	var typeWrap = $('#soft_kb_types');
	if (typeWrap.length && jawnSoftTypes && jawnSoftTypes.length) {
		var types = $('#soft_kb_types_rows').empty();
		for (var t = 0; t < jawnSoftTypes.length; t++) {
			var ty = jawnSoftTypes[t] || {};
			if (!ty.key) { continue; }
			var chip = $('<button type="button" class="soft_kb_convert_item soft_kb_type_item"></button>')
				.attr({ 'data-kb_type': ty.key, 'data-kb_type_unit': ty.unit || '', 'aria-label': softKbTypeLabel(ty.key) })
				.text(softKbTypeLabel(ty.key));
			if (ty.key == jawnSoftType) { chip.addClass('active'); }
			chip.appendTo(types);
		}
		typeWrap.prop('hidden', false);
	}
	$('#soft_kb_convert_src').text(r.text || (r.value + ' ' + r.unit));
	// the units used most first, then the registry's own order
	var use = softKbUseLoad();
	var rows = (r.rows || []).slice(0);
	rows.sort(function (a, b) { return (Number(use[b.unit]) || 0) - (Number(use[a.unit]) || 0); });
	if (rows.length > JAWN_SOFT_CONVERT_MAX) { rows.length = JAWN_SOFT_CONVERT_MAX; }
	var box = $('#soft_kb_convert_rows').empty();
	for (var i = 0; i < rows.length; i++) {
		var row = rows[i];
		$('<button type="button" class="soft_kb_convert_item"></button>')
			.attr({
				'data-kb_convert_unit': row.unit,
				'data-kb_convert_value': row.value,
				title: (row.name || row.unit),
				'aria-label': (row.text || '') + ' ' + (row.name || '')
			})
			.text(row.text || (row.value + ' ' + row.unit))
			.appendTo(box);
	}
	wrap.prop('hidden', false);
	softKbReserve();
}

// Choosing a kind converts from the unit last used for that kind (or the kind's
// own representative), so the row changes without retyping a unit.
function softKbTypePick(type, unit) {
	if (!type) { return; }
	var src = unit;
	try { src = localStorage.getItem('jawn_soft_unit_' + type) || unit; } catch (err) {}
	if (!src) { return; }
	jawnSoftUnit = src;
	jawnSoftType = type;
	try { localStorage.setItem('jawn_soft_calc_unit', src); } catch (err) {}
	softKbConvertUpdate();
}

// Tapping a conversion uses its answer: a number field takes it as the value,
// and it becomes the remembered unit so the next number converts from there.
function softKbConvertPick(unit, value) {
	value = softKbNumber(value);
	if (unit) {
		jawnSoftUnit = unit;
		softKbUseAdd(unit);
		try {
			localStorage.setItem('jawn_soft_calc_unit', unit);
			if (jawnSoftType) { localStorage.setItem('jawn_soft_unit_' + jawnSoftType, unit); }
		} catch (err) {}
	}
	if (value == null) { return; }
	if (jawnSoftNumeric && jawnSoftField) {
		jawnSoftExpr = String(value);
		softKbCalcRender();
		softKbCalcSyncNumeric();
		try { jawnSoftField.focus({ preventScroll: true }); } catch (err) {}
		softKbConvertUpdate();
		return;
	}
	if (jawnSoftMode == 'calc') {
		jawnSoftExpr = String(value);
		softKbCalcRender();
	}
	softKbInsert(String(value));
	softKbConvertUpdate();
}

// ---- the same conversions, beside the field -------------------------------
// The dock is a phone's keyboard. A desk types with its own and the dock stays
// closed, but a quantity that names a unit (32.33L, $32.31, 5jpy) still has
// every other unit of its kind to offer, so that row rides just above the field
// being typed in. It is the same parse and the same server answer as the dock's
// row; only the place is different, and the quantity is replaced by the answer
// instead of the number being appended at the caret.
var jawnMeasureField = null;
var jawnMeasureHit = null;
var jawnMeasureTimer = null;
var jawnMeasureSeq = 0;
var jawnMeasureHideTimer = null;
var jawnMeasureQuiet = 0;

function jawnMeasureUsable(el) {
	if (!el || el.nodeType != 1) { return false; }
	if ($(el).closest('#jawn_soft_keyboard, #jawn_measure_pop').length) { return false; }
	return softKbEditable(el);
}

function jawnMeasureText(el) {
	if (!el) { return ''; }
	return el.isContentEditable ? $(el).text() : (el.value || '');
}

// The template carries this row; a page that was rendered before it existed
// still gets one, so the feature cannot depend on a stale template.
function jawnMeasureRoot() {
	var pop = $('#jawn_measure_pop');
	if (!pop.length) {
		pop = $('<div id="jawn_measure_pop" class="soft_kb_convert" hidden><span id="jawn_measure_pop_src" class="soft_kb_convert_src"></span><div id="jawn_measure_pop_rows" class="soft_kb_convert_rows"></div></div>');
		$('body').append(pop);
	}
	return pop;
}

function jawnMeasureHide() {
	clearTimeout(jawnMeasureTimer);
	jawnMeasureSeq++;
	jawnMeasureHit = null;
	var pop = $('#jawn_measure_pop');
	if (pop.length && !pop.prop('hidden')) { pop.prop('hidden', true); }
}

function jawnMeasureFocus(el) {
	if (!jawnMeasureUsable(el)) { jawnMeasureField = null; jawnMeasureHide(); return; }
	jawnMeasureField = el;
	jawnMeasureUpdate();
}

function jawnMeasureUpdate() {
	var el = jawnMeasureField;
	if (!el || !document.contains(el)) { jawnMeasureHide(); return; }
	if (Date.now() - jawnMeasureQuiet < 400) { return; }
	// the dock's own row is the one to read while the keys are up
	if (softKbVisible()) { jawnMeasureHide(); return; }
	// a time, a length, a warranty or a repeat names its own units; "5m" there
	// is five minutes and must not be read as metres. Another kind of quantity
	// in such a field (32.33 L, $5) still converts - only the time-shaped units
	// are left to the field.
	var context = softKbContext(el);
	if (context == 'password') { jawnMeasureHide(); return; }
	var hit = softKbConvertParse(jawnMeasureText(el), true);
	if (!hit) { jawnMeasureHide(); return; }
	if ((context == 'when' || context == 'duration' || context == 'warranty' || context == 'schedule')
		&& /^(s|m|min|mins|h|hr|hrs|d|w|M|mo|y|yr)$/.test(hit.unit)) {
		jawnMeasureHide();
		return;
	}
	jawnMeasureHit = hit;
	var seq = ++jawnMeasureSeq;
	clearTimeout(jawnMeasureTimer);
	jawnMeasureTimer = setTimeout(function () {
		$.get('/manager/keyboard/convert', { unit: hit.unit, value: hit.value }, function (r) {
			if (seq != jawnMeasureSeq) { return; }
			if (!r || !r.ok || !r.rows || !r.rows.length) { jawnMeasureHide(); return; }
			jawnMeasureRender(r, hit);
		}, 'json').fail(function () {
			if (seq == jawnMeasureSeq) { jawnMeasureHide(); }
		});
	}, 260);
}

function jawnMeasureRender(r, hit) {
	var pop = jawnMeasureRoot();
	jawnSoftUnit = r.unit || (hit && hit.unit) || jawnSoftUnit;
	try { localStorage.setItem('jawn_soft_calc_unit', jawnSoftUnit); } catch (err) {}
	$('#jawn_measure_pop_src').text(r.text || ((r.value != null ? r.value : hit.value) + ' ' + jawnSoftUnit));
	var use = softKbUseLoad();
	var rows = (r.rows || []).slice(0);
	rows.sort(function (a, b) { return (Number(use[b.unit]) || 0) - (Number(use[a.unit]) || 0); });
	if (rows.length > JAWN_SOFT_CONVERT_MAX) { rows.length = JAWN_SOFT_CONVERT_MAX; }
	var box = $('#jawn_measure_pop_rows').empty();
	for (var i = 0; i < rows.length; i++) {
		var row = rows[i];
		var text = row.text || (row.value + ' ' + row.unit);
		$('<button type="button" class="soft_kb_convert_item"></button>')
			.attr({
				'data-measure_unit': row.unit,
				'data-measure_value': row.value,
				'data-measure_text': text,
				title: (row.name || row.unit),
				'aria-label': text + ' ' + (row.name || '')
			})
			.text(text)
			.appendTo(box);
	}
	pop.prop('hidden', false);
	jawnMeasurePlace();
}

// Above the field, or below it when the top of the page has no room. The row
// keeps the field's own width where it can, and never runs off the screen.
function jawnMeasurePlace() {
	var pop = $('#jawn_measure_pop');
	var el = jawnMeasureField;
	if (!pop.length || pop.prop('hidden') || !el || !document.contains(el)) { return; }
	var rect = el.getBoundingClientRect();
	var vw = window.innerWidth || $(window).width();
	var vh = window.innerHeight || $(window).height();
	if (rect.bottom < 0 || rect.top > vh) { jawnMeasureHide(); return; }
	var width = Math.min(Math.max(rect.width, 240), 460, vw - 16);
	pop.css('width', width + 'px');
	var h = pop.outerHeight() || 0;
	var gap = 8;
	var left = Math.max(8, Math.min(rect.left, vw - width - 8));
	var top = rect.top - h - gap;
	if (top < 8) { top = Math.min(vh - h - 8, rect.bottom + gap); }
	pop.css({ left: left + 'px', top: Math.max(8, top) + 'px' });
}

// Tapping a conversion writes its answer: a number field takes the number, and
// a text field has the quantity it typed (unit and all) replaced by the answer.
function jawnMeasurePick(unit, value, text) {
	var el = jawnMeasureField;
	var hit = jawnMeasureHit;
	if (!el) { return; }
	var num = softKbNumber(value);
	if (unit) {
		jawnSoftUnit = unit;
		softKbUseAdd(unit);
		try {
			localStorage.setItem('jawn_soft_calc_unit', unit);
			if (jawnSoftType) { localStorage.setItem('jawn_soft_unit_' + jawnSoftType, unit); }
		} catch (err) {}
	}
	jawnMeasureQuiet = Date.now();
	if (num != null) {
		if (!el.isContentEditable && softKbNumeric(el)) {
			el.value = String(num);
			try { el.focus({ preventScroll: true }); el.setSelectionRange(el.value.length, el.value.length); } catch (err) {}
			softKbNotify(el);
		}
		else if (!el.isContentEditable && hit && text) {
			var start = hit.at;
			var end = hit.at + (hit.len || 0);
			if (start < 0 || start > el.value.length) { start = el.value.length; end = start; }
			if (end > el.value.length || end < start) { end = el.value.length; }
			el.value = el.value.slice(0, start) + text + el.value.slice(end);
			try { el.focus({ preventScroll: true }); el.setSelectionRange(start + text.length, start + text.length); } catch (err) {}
			softKbNotify(el);
		}
		else {
			softKbInsert(text || String(num), el);
		}
	}
	jawnMeasureHide();
}

// The row answers a press without taking the caret out of the field. A chip
// answers a release that did not travel, the way the dock's own chips do, so a
// sideways drag along the row pans it instead of choosing.
var jawnMeasureTap = null;
$(document).on('pointerdown', '#jawn_measure_pop button', function (e) {
	if (e.button != null && e.button != 0) { return; }
	e.preventDefault();
	jawnMeasureTap = { x: e.clientX, y: e.clientY, el: this };
});
$(document).on('pointerup', '#jawn_measure_pop button', function (e) {
	var tap = jawnMeasureTap;
	jawnMeasureTap = null;
	if (!tap || tap.el !== this) { return; }
	if (Math.abs((e.clientX || 0) - tap.x) > 12 || Math.abs((e.clientY || 0) - tap.y) > 12) { return; }
	e.preventDefault();
	jawnMeasurePick($(this).attr('data-measure_unit'), $(this).attr('data-measure_value'), $(this).attr('data-measure_text'));
});
$(document).on('pointerup pointercancel', function () { jawnMeasureTap = null; });

$(document).on('focusin', function (e) { jawnMeasureFocus(e.target); });

$(document).on('focusout', function (e) {
	if (e.target !== jawnMeasureField) { return; }
	clearTimeout(jawnMeasureHideTimer);
	jawnMeasureHideTimer = setTimeout(function () {
		if ($(document.activeElement).closest('#jawn_measure_pop').length) { return; }
		jawnMeasureHide();
		jawnMeasureField = null;
	}, 240);
});

// typing in a contenteditable fires input too; the dock's own listener covers
// input and textarea
if (document.addEventListener) {
	document.addEventListener('input', function (e) {
		if (e.target && e.target === jawnMeasureField) { jawnMeasureUpdate(); }
	}, true);
}

document.addEventListener('scroll', function () {
	if (!jawnMeasureField) { return; }
	var pop = document.getElementById('jawn_measure_pop');
	if (!pop || pop.hidden) { return; }
	jawnMeasurePlace();
}, true);

// ---- what the field is asking for ------------------------------------------
// The row names the kind of value the field wants. A tap writes the whole value
// (instead of appending it) because these fields hold one answer, and the value
// goes through input/keyup/change so the app saves it the way typing would.
var jawnSoftSuggestDefs = {
	when: {
		label: 'Time',
		items: ['now', '5m', '15m', '1h', '4h', '1d', '1w', '1M', 'yesterday', 'today', 'tomorrow', 'in 1h', 'in 1d']
	},
	duration: {
		label: 'Duration',
		items: ['5m', '15m', '30m', '1h', '2h', '4h', '8h', '1d', '1w']
	},
	warranty: {
		label: 'Warranty',
		items: ['-1d', '-1w', '-1M', '-3M', '-6M', '-1y', '-2y', '-5y', '-10y']
	},
	schedule: {
		label: 'Repeat',
		items: ['once', '1d', '1w', '1M', '1y', '1d for -2w', '1w for -8w']
	}
};

function softKbSuggestText() {
	var el = jawnSoftField;
	if (!el) { return ''; }
	return el.isContentEditable ? $(el).text() : (el.value || '');
}

// A number already typed steers the row: 5 in a time field offers 5s, 5m, 5h,
// 5d, 5w, 5M and 5y, in a duration 5m through 5y, and a warranty takes them
// negative. The fixed chips follow, without repeats.
function softKbSuggestItems(def) {
	var items = [];
	var found = String(softKbSuggestText() || '').match(/\d+(?:\.\d+)?/g);
	var n = found ? found[found.length - 1] : '';
	if (n) {
		var units = (jawnSoftContext == 'when') ? ['s', 'm', 'h', 'd', 'w', 'M', 'y'] : ['m', 'h', 'd', 'w', 'M', 'y'];
		for (var i = 0; i < units.length; i++) {
			var v = n + units[i];
			if (jawnSoftContext == 'warranty') { v = '-' + v; }
			items.push(v);
		}
	}
	for (var j = 0; j < def.items.length; j++) {
		if (items.indexOf(def.items[j]) < 0) { items.push(def.items[j]); }
	}
	return items;
}

function softKbSuggestSync() {
	var wrap = $('#soft_kb_suggest');
	var def = jawnSoftSuggestDefs[jawnSoftContext];
	if (!def || !jawnSoftField) {
		if (wrap.length && !wrap.prop('hidden')) { wrap.prop('hidden', true); softKbReserve(); }
		return;
	}
	var was = wrap.prop('hidden');
	$('#soft_kb_suggest_label').text(softKbLabel(def.label));
	var items = softKbSuggestItems(def);
	var rows = $('#soft_kb_suggest_rows').empty();
	for (var i = 0; i < items.length; i++) {
		$('<button type="button" class="soft_kb_convert_item"></button>')
			.attr({ 'data-kb_suggest': items[i], 'aria-label': items[i] })
			.text(items[i])
			.appendTo(rows);
	}
	wrap.prop('hidden', false);
	if (was) { softKbReserve(); }
}

function softKbSuggestPick(value) {
	var el = jawnSoftField;
	if (!el || value == null) { return; }
	if (el.isContentEditable) { softKbInsert(value); return; }
	el.value = value;
	try { el.focus({ preventScroll: true }); el.setSelectionRange(value.length, value.length); } catch (err) {}
	softKbNotify(el);
	$(el).trigger('change');
	softKbConvertUpdate();
	softKbSuggestSync();
}

function softKbFormat(value) {
	var out = String(Math.round(value * 1e12) / 1e12);
	if (out.indexOf('e') >= 0 || out.length > 18) { out = String(parseFloat(value.toPrecision(12))); }
	return out;
}

// A small recursive-descent evaluation: + - * /, parentheses, unary signs and a
// postfix percent. No eval, and anything outside that grammar is refused.
function softKbEval(source) {
	var s = String(source).replace(/×/g, '*').replace(/÷/g, '/').replace(/−/g, '-').replace(/\s+/g, '');
	var i = 0;
	function factor() {
		if (s[i] == '+') { i++; return factor(); }
		if (s[i] == '-') { i++; return -factor(); }
		if (s[i] == '(') {
			i++;
			var v = expression();
			if (s[i] != ')') { throw new Error('parenthesis'); }
			i++;
			return v;
		}
		var start = i;
		while (i < s.length && /[0-9.]/.test(s[i])) { i++; }
		if (start == i) { throw new Error('number'); }
		var n = parseFloat(s.slice(start, i));
		if (!isFinite(n)) { throw new Error('number'); }
		while (s[i] == '%') { n = n / 100; i++; }
		return n;
	}
	function term() {
		var v = factor();
		while (s[i] == '*' || s[i] == '/') {
			var op = s[i++];
			var r = factor();
			v = (op == '*') ? v * r : v / r;
		}
		return v;
	}
	function expression() {
		var v = term();
		while (s[i] == '+' || s[i] == '-') {
			var op = s[i++];
			var r = term();
			v = (op == '+') ? v + r : v - r;
		}
		return v;
	}
	var result = expression();
	if (i != s.length) { throw new Error('trailing'); }
	return result;
}

// ---- the magnified key under a finger --------------------------------------
// While a character key is held, a large copy of it rides above the key, the
// way a phone's own keyboard shows what the finger is covering. It lives on the
// body rather than inside the dock so a window's overflow cannot clip it, and it
// is shown only for keys that type a character - a modifier has no letter to
// enlarge.
var jawnSoftMagnify = null;

function softKbMagnifyEl() {
	if (!jawnSoftMagnify) {
		jawnSoftMagnify = $('<div id="soft_kb_magnify" class="soft_kb_magnify" aria-hidden="true"></div>').appendTo('body');
	}
	if (!jawnSoftMagnify.parent().length || !$.contains(document.documentElement, jawnSoftMagnify[0])) {
		jawnSoftMagnify.appendTo('body');
	}
	return jawnSoftMagnify;
}

function softKbMagnifyLabel(b) {
	if (b.attr('data-kb_char') != null) {
		var ch = String(b.attr('data-kb_char'));
		return ch.length ? ch : null;
	}
	var k = b.attr('data-kb_key');
	if (k == null) { return null; }
	// only a key that types something: shift, the arrows, space and the like
	// keep their ordinary pressed look
	if (String(k).length != 1) { return null; }
	// the key's printed face is what the finger is covering (the calculator's
	// ÷ and × are drawn over a different data-kb_key)
	var face = String(b.text() || '').replace(/\s+/g, ' ').trim();
	return face || String(k);
}

// Place the bubble above the key, or below it when the key is near the top of
// the screen, and never off the side of the viewport.
function softKbMagnifyPlace(el, rect) {
	var vw = window.innerWidth || $(window).width() || 0;
	var vh = window.innerHeight || $(window).height() || 0;
	var w = el.outerWidth() || 54;
	var h = el.outerHeight() || 58;
	var cx = rect.left + rect.width / 2;
	var half = w / 2 + 6;
	if (cx < half) { cx = half; }
	if (vw && cx > vw - half) { cx = vw - half; }
	var below = (rect.top - 8 - h) < 6;
	var top = below ? (rect.bottom + 8) : (rect.top - 8);
	if (vh && top > vh - 6) { top = vh - 6; }
	el.toggleClass('soft_kb_magnify_below', below).css({ left: cx + 'px', top: top + 'px' });
}

function softKbMagnifyShow(b) {
	var label = softKbMagnifyLabel(b);
	if (label == null || !b.length || !b[0].getBoundingClientRect) { return; }
	// a key pressed while the dock is still rising would leave the bubble where
	// the key was mid-slide, so this press gets the plain pressed look instead
	if (jawnSoftSlideAt && (Date.now() - jawnSoftSlideAt) < softKbSlideMs()) { return; }
	var el = softKbMagnifyEl();
	var rect = b[0].getBoundingClientRect();
	el.text(label).prop('hidden', false).addClass('on');
	softKbMagnifyPlace(el, rect);
}

function softKbMagnifyHide() {
	if (!jawnSoftMagnify) { return; }
	jawnSoftMagnify.removeClass('on soft_kb_magnify_below').prop('hidden', true);
}

// ---- keys ------------------------------------------------------------------
function softKbKey(k) {
	if (k == 'shift') { softKbShiftSet(!jawnSoftShift); return; }
	if (k == 'backspace') {
		if (jawnSoftMode == 'calc') { softKbCalcKey('backspace'); } else { softKbBackspace(); }
		return;
	}
	if (k == 'enter') { softKbEnter(); return; }
	if (jawnSoftMode == 'calc') { softKbCalcKey(k); return; }
	if (k == 'space') { softKbInsert(' '); return; }
	if (k && k.length) {
		var layout = softKbLayout();
		var out = (jawnSoftShift && layout.cased !== false) ? softKbUpper(k, layout) : k;
		softKbInsert(out);
		if (jawnSoftShift) { softKbShiftSet(false); }
	}
}

function softKbChar(c) {
	if (jawnSoftMode == 'calc') {
		var map = { '×': '*', '÷': '/', '−': '-', '–': '-', '+': '+', '%': '%', '(': '(', ')': ')', '=': '=' };
		if (map[c] != null) { softKbCalcKey(map[c]); }
		else if (c == '±') { softKbCalcKey('sign'); }
		return;
	}
	if (jawnSoftField && !jawnSoftNumeric) { softKbInsert(c); }
}

function softKbPress(b) {
	if (b.attr('data-kb_mode')) { softKbModeSet(b.attr('data-kb_mode')); return; }
	if (b.attr('data-kb_layout')) { softKbLayoutSet(b.attr('data-kb_layout')); return; }
	if (b.attr('data-kb_action') == 'layouts') { softKbLayoutsToggle(); return; }
	if (b.attr('data-kb_action') == 'layouts_close') { softKbLayoutsToggle(false); return; }
	if (b.attr('data-kb_action') == 'dictate') { softKbDictateToggle(); return; }
	if (b.attr('data-kb_action') == 'close') { jawnSoftForced = false; softKbHide(); return; }
	if (b.attr('data-kb_action') == 'clear_history') {
		jawnSoftHistory = [];
		softKbHistorySave();
		softKbHistoryRender();
		return;
	}
	if (b.attr('data-kb_history') != null) { softKbHistoryPick(b.attr('data-kb_history')); return; }
	if (b.attr('data-kb_convert_unit') != null) { softKbConvertPick(b.attr('data-kb_convert_unit'), b.attr('data-kb_convert_value')); return; }
	if (b.attr('data-kb_type') != null) { softKbTypePick(b.attr('data-kb_type'), b.attr('data-kb_type_unit')); return; }
	if (b.attr('data-kb_suggest') != null) { softKbSuggestPick(b.attr('data-kb_suggest')); return; }
	if (b.attr('data-kb_char') != null) { softKbChar(b.attr('data-kb_char')); return; }
	var k = b.attr('data-kb_key');
	if (k == null) { return; }
	softKbKey(k);
}

// A chip in the conversion/history/recommendation row sits inside a sideways
// scroller. It must not act on pointerdown, or a swipe becomes a tap; record
// where the finger landed and act on a release that did not travel.
var jawnSoftChipStart = null;
var jawnSoftChipAt = 0;

$(document).on('pointerdown', '#jawn_soft_keyboard button', function (e) {
	if (e.button != null && e.button != 0) { return; }
	if ($(this).hasClass('soft_kb_convert_item') || $(this).hasClass('soft_kb_history_item') || $(this).hasClass('soft_kb_layout_item')) {
		jawnSoftChipStart = { x: e.clientX, y: e.clientY, el: this };
		return;
	}
	// act on the press and keep the caret in the field
	e.preventDefault();
	jawnSoftKeyAt = Date.now();
	softKbMagnifyShow($(this));
	if ($(this).attr('data-kb_key') == 'backspace') { softKbBackspaceDown(this); return; }
	// any other key puts a hold on backspace away
	softKbRepeatStop();
	softKbPress($(this));
});
$(document).on('pointerup', '#jawn_soft_keyboard button', function (e) {
	if (!jawnSoftChipStart) { return; }
	var start = jawnSoftChipStart;
	jawnSoftChipStart = null;
	if (!$(this).hasClass('soft_kb_convert_item') && !$(this).hasClass('soft_kb_history_item') && !$(this).hasClass('soft_kb_layout_item')) { return; }
	var dx = Math.abs((e.clientX || 0) - start.x);
	var dy = Math.abs((e.clientY || 0) - start.y);
	if (dx > 12 || dy > 12) { jawnSoftChipAt = Date.now(); return; }   // a swipe, not a tap
	e.preventDefault();
	jawnSoftChipAt = Date.now();
	softKbPress($(start.el));
});
$(document).on('pointerup pointercancel', '#jawn_soft_keyboard button', function () {
	softKbMagnifyHide();
	softKbRepeatStop();
});
$(document).on('pointerup pointercancel', function () { softKbMagnifyHide(); if (jawnSoftChipStart) { jawnSoftChipAt = Date.now(); jawnSoftChipStart = null; } softKbRepeatStop(); });
$(window).on('blur', function () { softKbMagnifyHide(); });
$(document).on('click', '#jawn_soft_keyboard button', function () {
	if (Date.now() - jawnSoftKeyAt < 600) { return; }
	if (Date.now() - jawnSoftChipAt < 700) { return; }
	// a long hold can outlive the press guard; its release must not delete again
	if ($(this).attr('data-kb_key') == 'backspace' && Date.now() - jawnSoftHoldAt < 800) { return; }
	softKbPress($(this));
});
$(document).on('pointerdown', '#jawn_soft_keyboard', function (e) {
	if (!$(e.target).closest('button').length && !$(e.target).closest('.soft_kb_convert_rows').length) { e.preventDefault(); }
});

// ---- attaching to fields ---------------------------------------------------
// Sweep the page and every window it adds: the platform keyboard is told to
// stay away before the field can ask for it, not after it has opened.
function softKbSweep(root) {
	if (!softKbOn() || !$('#jawn_soft_keyboard').length) { return; }
	$(root).find('input, textarea, [contenteditable="true"]').addBack('input, textarea, [contenteditable="true"]').each(function () {
		if (softKbEditable(this) && this.getAttribute('data-soft_inputmode') == null) { softKbSuppress(this); }
	});
}
var softKbSweepTimer;
if (window.MutationObserver) {
	new MutationObserver(function () {
		clearTimeout(softKbSweepTimer);
		softKbSweepTimer = setTimeout(function () { softKbSweep(document); }, 150);
	}).observe(document.documentElement, { childList: true, subtree: true });
}
$(function () { softKbSweep(document); });

// ---- selecting text by dragging --------------------------------------------
// A finger dragged across a field selects from where it landed as it moves, so
// the highlight appears at once instead of waiting for the platform's long-press
// handles. Chromium reports the caret inside an input/textarea through
// caretPositionFromPoint; a contenteditable reports its text node.
var jawnTextDrag = null;

function jawnTextSelectable(el) {
	if (!el || el.nodeType != 1 || el.disabled) { return false; }
	if (el.isContentEditable) { return true; }
	var tag = (el.tagName || '').toLowerCase();
	if (tag == 'textarea') { return true; }
	if (tag != 'input') { return false; }
	var type = (el.getAttribute('type') || 'text').toLowerCase();
	return ['text', 'search', 'email', 'url', 'tel', 'password'].indexOf(type) >= 0;
}

function jawnTextCaretAt(x, y) {
	try {
		if (document.caretPositionFromPoint) {
			var p = document.caretPositionFromPoint(x, y);
			if (p && p.offsetNode) { return { node: p.offsetNode, offset: p.offset }; }
		}
		if (document.caretRangeFromPoint) {
			var r = document.caretRangeFromPoint(x, y);
			if (r) { return { node: r.startContainer, offset: r.startOffset }; }
		}
	} catch (err) {}
	return null;
}

function jawnTextOwns(field, node) {
	if (!node) { return false; }
	if (node === field) { return true; }
	return field.contains(node);
}

function jawnTextDragAnchor(d) {
	var el = d.el;
	var a = jawnTextCaretAt(d.x, d.y);
	if (el.isContentEditable) {
		if (a && jawnTextOwns(el, a.node)) { d.anchorNode = a.node; d.anchorOffset = a.offset; return; }
		d.anchorNode = el;
		d.anchorOffset = 0;
		return;
	}
	if (a && a.node === el) { d.anchor = a.offset; return; }
	d.anchor = (el.selectionStart == null) ? 0 : el.selectionStart;
}

function jawnTextDragOffset(d, x, y) {
	var el = d.el;
	var a = jawnTextCaretAt(x, y);
	if (el.isContentEditable) {
		if (a && jawnTextOwns(el, a.node)) { return a; }
		var r = el.getBoundingClientRect();
		var range = document.createRange();
		range.selectNodeContents(el);
		range.collapse(y < r.top || (y <= r.bottom && x < r.left));
		return { node: range.startContainer, offset: range.startOffset };
	}
	if (a && a.node === el) { return { node: el, offset: a.offset }; }
	var rect = el.getBoundingClientRect();
	var before = (y < rect.top) || (y <= rect.bottom && x < rect.left);
	return { node: el, offset: before ? 0 : (el.value || '').length };
}

function jawnTextDragApply(d, x, y) {
	var el = d.el;
	var cur = jawnTextDragOffset(d, x, y);
	if (!cur) { return; }
	if (el.isContentEditable) {
		if (d.anchorNode == null) { return; }
		var sel = window.getSelection ? window.getSelection() : null;
		if (!sel) { return; }
		var range = document.createRange();
		try {
			range.setStart(d.anchorNode, d.anchorOffset);
			range.setEnd(d.anchorNode, d.anchorOffset);
			var probe = document.createRange();
			probe.setStart(cur.node, cur.offset);
			probe.setEnd(cur.node, cur.offset);
			if (range.compareBoundaryPoints(Range.START_TO_START, probe) <= 0) {
				range.setEnd(cur.node, cur.offset);
			}
			else {
				range.setStart(cur.node, cur.offset);
				range.setEnd(d.anchorNode, d.anchorOffset);
			}
		} catch (err) { return; }
		sel.removeAllRanges();
		sel.addRange(range);
		return;
	}
	var a = (d.anchor == null) ? 0 : d.anchor;
	var o = cur.offset;
	try { el.setSelectionRange(Math.min(a, o), Math.max(a, o)); } catch (err) {}
}

$(document).on('pointerdown', 'input, textarea, [contenteditable="true"]', function (e) {
	if (e.pointerType === 'mouse') { return; }
	if (e.isPrimary === false) { return; }
	var el = softKbRoot(this);
	if (!jawnTextSelectable(el)) { return; }
	jawnTextDrag = { el: el, x: e.clientX, y: e.clientY, pointerId: e.pointerId, moved: false, anchor: null, anchorNode: null, anchorOffset: 0 };
});

$(document).on('pointermove', function (e) {
	var d = jawnTextDrag;
	if (!d) { return; }
	if (e.pointerId != null && d.pointerId != null && e.pointerId !== d.pointerId) { return; }
	if (!d.moved) {
		if (Math.abs(e.clientX - d.x) < 6 && Math.abs(e.clientY - d.y) < 6) { return; }
		d.moved = true;
		// the field is focused so the selection is visible, but the dock stays
		// down: this is a selection, not a tap that asks to type
		jawnSoftDragFocus = true;
		try { d.el.focus({ preventScroll: true }); } catch (err) {}
		setTimeout(function () { jawnSoftDragFocus = false; }, 0);
		jawnTextDragAnchor(d);
	}
	e.preventDefault();
	jawnTextDragApply(d, e.clientX, e.clientY);
});

$(document).on('pointerup pointercancel', function (e) {
	var d = jawnTextDrag;
	if (!d) { return; }
	if (e && e.pointerId != null && d.pointerId != null && e.pointerId !== d.pointerId) { return; }
	jawnTextDrag = null;
	// the click that closes a drag ends a selection; it is not a tap on the field
	if (d.moved) {
		jawnSoftDragClick = true;
		setTimeout(function () { jawnSoftDragClick = false; }, 350);
	}
});

document.addEventListener('pointerdown', function (e) {
	var el = e.target;
	if (softKbOn() && (softKbEditable(el) || (el.isContentEditable))) { softKbSuppress(el); }
}, true);
document.addEventListener('touchstart', function (e) {
	var el = e.target;
	// a finger means the phone is back in hand, even if a Bluetooth keyboard was
	// used a moment ago
	if (jawnSoftHardware) { softKbHardwareClear(); }
	if (softKbOn() && (softKbEditable(el) || (el.isContentEditable))) { softKbSuppress(el); }
}, true);

// The only honest test for a real keyboard is a real key: the page may not
// enumerate input devices, but a trusted key press is proof enough. It puts the
// dock away at once and keeps it away, so a desk never has to dismiss it twice.
// Modifier-only keys and shortcuts are not typing, and the dock's own buttons
// are not evidence of anything.
document.addEventListener('keydown', function (e) {
	if (!e || e.isTrusted === false) { return; }
	if (e.ctrlKey || e.metaKey || e.altKey) { return; }
	var k = e.key || '';
	if (!k) { return; }
	if (k == 'Escape') { jawnMeasureHide(); return; }
	if (k == 'Shift' || k == 'Alt' || k == 'Control' || k == 'Meta' || k == 'CapsLock' || k == 'Tab') { return; }
	var target = e.target;
	if (target && target.closest && target.closest('#jawn_soft_keyboard, #jawn_measure_pop')) { return; }
	softKbHardwareMark();
}, true);

$(document).on('focusin', function (e) {
	var el = e.target;
	if (!softKbOn() || !softKbEditable(el)) { return; }
	softKbSuppress(el);
	// a drag across the field focuses it to show the selection; that focus must
	// not raise the keys, so scrolling or selecting never opens the keyboard
	if (jawnSoftDragFocus) { return; }
	softKbShow(el);
});

$(document).on('click', 'input, textarea, [contenteditable="true"]', function () {
	if (!softKbOn() || !softKbEditable(this)) { return; }
	if (jawnSoftDragClick) { return; }
	softKbShow(this);
});

$(document).on('focusout', function (e) {
	if (!softKbEditable(e.target)) { return; }
	clearTimeout(jawnSoftHideTimer);
	jawnSoftHideTimer = setTimeout(function () {
		var active = document.activeElement;
		if ($(active).closest('#jawn_soft_keyboard').length) { return; }
		if ($(active).is('#chat_soft_toggle')) { return; }
		if (softKbEditable(active) && softKbOn()) { return; }
		softKbHide();
	}, 260);
});

// A number field typed into from a hardware keyboard keeps the calculator in step.
$(document).on('input', 'input, textarea', function () {
	if (this === jawnSoftField && jawnSoftNumeric && !jawnSoftSetting) {
		jawnSoftExpr = this.value || '';
		$('#soft_kb_expr').text(jawnSoftExpr || '0');
		$('#soft_kb_result').text('');
	}
	if (this === jawnSoftField) { softKbConvertUpdate(); softKbSuggestSync(); }
});

// The Chat composer's keyboard button asks for the dock; pressing it again puts
// it away. It also turns the dock on for a desk that has not asked for it yet.
$(document).on('click', '#chat_soft_toggle', function () {
	var el = document.getElementById('message');
	if (!el) { return; }
	if (softKbVisible() && jawnSoftField === el) { jawnSoftForced = false; softKbHide(); return; }
	softKbForce();
	try { el.focus({ preventScroll: true }); } catch (err) { el.focus(); }
	softKbShow(el);
});

// Sending must not put the dock away.
$(document).on('click', '#send_it', function () {
	if (!jawnSoftField || jawnSoftField.id != 'message' || !softKbVisible()) { return; }
	setTimeout(function () {
		var el = document.getElementById('message');
		if (!el) { return; }
		try { el.focus({ preventScroll: true }); } catch (err) { el.focus(); }
	}, 0);
});

$(window).on('resize', function () { if (softKbVisible()) { softKbReserve(); } jawnMeasurePlace(); });

$(function () {
	softKbHistoryRender();
	softKbLayoutRender();
	softKbLayoutsRender();
	softKbMicState();
	softKbUnitsLoad();
	// the row lives in the body, like the dock: a transformed ancestor would
	// make position:fixed a child of that ancestor instead of the page
	var measure_pop = $('#jawn_measure_pop');
	if (measure_pop.length && !measure_pop.parent().is('body')) { $('body').append(measure_pop); }
	try { jawnSoftUnit = localStorage.getItem('jawn_soft_calc_unit') || null; } catch (err) {}
	// a bare number in the calculator starts in the house's own currency, so
	// the conversion row is there before a unit has been typed
	if (!jawnSoftUnit) { jawnSoftUnit = jawnSoftBase || null; }
});
