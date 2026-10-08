// The IDE's code view: the textarea keeps the text and the caret, and a <pre>
// behind it shows the same text through a small tokeniser. The textarea's own
// ink is transparent, so what is typed is what is coloured; the two boxes
// share a font, a padding and a border, and they scroll as one.
//
// The languages are the ones this house writes in: perl, javascript, html,
// and the .html.ep templates, which are html with perl inside it.

function ideCodeEscape(text) {
	return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function ideCodeSpan(cls, text) {
	return '<span class="' + cls + '">' + ideCodeEscape(text) + '</span>';
}

// One rule per kind of token, tried in order, so a comment outranks a string
// that starts inside it and a string outranks the words inside it. Each is
// matched on its own as well, to know which rule the master match belongs to.
var ideCodeRules = {
	perl: [
		{ re: /#[^\n]*/, cls: 'ide_tok_comment' },
		{ re: /'(?:\\.|[^'\\\n])*'/, cls: 'ide_tok_string' },
		{ re: /"(?:\\.|[^"\\\n])*"/, cls: 'ide_tok_string' },
		{ re: /`(?:\\.|[^`\\])*`/, cls: 'ide_tok_string' },
		{ re: /\$(?:\{?[A-Za-z_][A-Za-z0-9_]*\}?)(?:(?:->|::)[A-Za-z_][A-Za-z0-9_]*)*/, cls: 'ide_tok_var' },
		{ re: /[@%][A-Za-z_][A-Za-z0-9_]*/, cls: 'ide_tok_var' },
		{ re: /\b(?:my|our|local|state|sub|use|require|package|if|elsif|else|unless|while|until|for|foreach|continue|do|return|last|next|redo|goto|die|warn|print|say|printf|sprintf|open|close|read|write|push|pop|shift|unshift|splice|split|join|map|grep|sort|reverse|keys|values|each|exists|delete|defined|undef|ref|bless|new|eval|not|and|or|xor|eq|ne|lt|gt|le|ge|cmp|qw|qq|qr|scalar|wantarray|mkdir|unlink|chmod|stat|system|exec|sleep|chomp|chop|lc|uc|lcfirst|ucfirst|length|substr|index|rindex|time|localtime|gmtime|int|abs|hex|oct|ord|chr)\b/, cls: 'ide_tok_keyword' },
		{ re: /[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)+/, cls: 'ide_tok_type' },
		{ re: /\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b/, cls: 'ide_tok_number' }
	],
	javascript: [
		{ re: /\/\/[^\n]*/, cls: 'ide_tok_comment' },
		{ re: /\/\*[\s\S]*?\*\//, cls: 'ide_tok_comment' },
		{ re: /"(?:\\.|[^"\\\n])*"/, cls: 'ide_tok_string' },
		{ re: /'(?:\\.|[^'\\\n])*'/, cls: 'ide_tok_string' },
		{ re: /`(?:\\.|[^`\\])*`/, cls: 'ide_tok_string' },
		{ re: /\b(?:var|let|const|function|return|if|else|for|while|do|switch|case|break|continue|new|delete|typeof|instanceof|this|true|false|null|undefined|async|await|class|extends|try|catch|finally|throw|in|of|yield|void|super|static|import|export|default)\b/, cls: 'ide_tok_keyword' },
		{ re: /[A-Za-z_$][A-Za-z0-9_$]*(?=\s*\()/, cls: 'ide_tok_func' },
		{ re: /\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b/, cls: 'ide_tok_number' }
	],
	html: [
		{ re: /<!--[\s\S]*?-->/, cls: 'ide_tok_comment' },
		{ re: /<[Dd][Oo][Cc][Tt][Yy][Pp][Ee][^>]*>/, cls: 'ide_tok_type' },
		{ re: /<\/?[A-Za-z][A-Za-z0-9._-]*/, cls: 'ide_tok_tag' },
		{ re: /[A-Za-z_:][A-Za-z0-9_.:-]*(?=\s*=)/, cls: 'ide_tok_attr' },
		{ re: /"[^"]*"|'[^']*'/, cls: 'ide_tok_string' },
		{ re: /&[a-zA-Z#0-9]+;/, cls: 'ide_tok_var' }
	],
	ep: [
		// <% ... %>, <%= ... %> and <%== ... %>: html outside, perl inside
		{ re: /<%[=-]?[\s\S]*?%>/, emit: function (m) {
			var whole = m[0];
			var open = whole.match(/^<%[=-]?/)[0];
			var inner = whole.slice(open.length, whole.length - 2);
			return ideCodeSpan('ide_tok_tag', open) + ideCodeHighlight(inner, 'perl') + ideCodeSpan('ide_tok_tag', '%>');
		} },
		// a line that starts with % is a line of perl in ep
		{ re: /^%[^\n]*/, emit: function (m) {
			return ideCodeSpan('ide_tok_tag', '%') + ideCodeHighlight(m[0].slice(1), 'perl');
		} },
		{ re: /<!--[\s\S]*?-->/, cls: 'ide_tok_comment' },
		{ re: /<[Dd][Oo][Cc][Tt][Yy][Pp][Ee][^>]*>/, cls: 'ide_tok_type' },
		{ re: /<\/?[A-Za-z][A-Za-z0-9._-]*/, cls: 'ide_tok_tag' },
		{ re: /[A-Za-z_:][A-Za-z0-9_.:-]*(?=\s*=)/, cls: 'ide_tok_attr' },
		{ re: /"[^"]*"|'[^']*'/, cls: 'ide_tok_string' },
		{ re: /&[a-zA-Z#0-9]+;/, cls: 'ide_tok_var' }
	]
};

function ideCodeHighlight(text, language) {
	var rules = ideCodeRules[language];
	if (!rules) { return ideCodeEscape(text); }
	if (!rules.master) {
		// one pass finds the next token; the rule list says which one it was
		rules.master = new RegExp(rules.map(function (r) { return '(?:' + r.re.source + ')'; }).join('|'), 'gm');
		rules.forEach(function (r) { r.anchor = new RegExp(r.re.source, 'ym'); });
	}
	var out = '';
	var pos = 0;
	rules.master.lastIndex = 0;
	var m;
	while ((m = rules.master.exec(text)) !== null) {
		out += ideCodeEscape(text.slice(pos, m.index));
		var rule = null;
		var match = m;
		for (var r = 0; r < rules.length; r++) {
			rules[r].anchor.lastIndex = m.index;
			var am = rules[r].anchor.exec(text);
			if (am && am.index === m.index) { rule = rules[r]; match = am; break; }
		}
		if (rule) {
			out += rule.emit ? rule.emit(match) : ideCodeSpan(rule.cls, match[0]);
		}
		else {
			out += ideCodeEscape(match[0]);
		}
		pos = m.index + match[0].length;
		if (match[0].length == 0) { pos++; }
		rules.master.lastIndex = pos;
	}
	out += ideCodeEscape(text.slice(pos));
	return out;
}

function ideCodeLanguage(file) {
	var name = String(file || '').toLowerCase();
	// .html.ep and .ep are templates: html with perl in it
	if (/\.ep$/.test(name)) { return 'ep'; }
	if (/\.(?:pl|pm)$/.test(name)) { return 'perl'; }
	if (/\.js$/.test(name)) { return 'javascript'; }
	if (/\.(?:html|htm)$/.test(name)) { return 'html'; }
	return '';
}

// ---- the editor on the page -------------------------------------------------

function ideCodeRefresh() {
	var ed = document.getElementById('ide_content');
	var view = document.getElementById('ide_highlight');
	if (!ed || !view) { return; }
	var code = view.querySelector('code');
	code.innerHTML = ideCodeHighlight(ed.value, ideCodeLanguage($(ed).attr('file')));
	ideCodeScroll();
	// scroll does not bubble, so the follower is bound to the editor itself
	$(ed).off('scroll.ide_code').on('scroll.ide_code', ideCodeScroll);
}

function ideCodeScroll() {
	var ed = document.getElementById('ide_content');
	var view = document.getElementById('ide_highlight');
	if (!ed || !view) { return; }
	view.scrollTop = ed.scrollTop;
	view.scrollLeft = ed.scrollLeft;
}

// typing colours the words a beat later, so a huge file cannot make the keys
// wait on the highlighter; anything that sets a whole file goes through
// ideCodeRefresh directly and is coloured at once
var ideCodeTimer = null;

function ideCodeQueued() {
	clearTimeout(ideCodeTimer);
	ideCodeTimer = setTimeout(ideCodeRefresh, 80);
}

$(document).on('input change', '#ide_content', function () {
	ideCodeQueued();
});

// Tab is a tab in an ide: two spaces, not a jump to the next control
$(document).on('keydown', '#ide_content', function (e) {
	if (e.key != 'Tab') { return; }
	e.preventDefault();
	var ed = this;
	var start = ed.selectionStart;
	var end = ed.selectionEnd;
	ed.value = ed.value.slice(0, start) + '  ' + ed.value.slice(end);
	ed.selectionStart = ed.selectionEnd = start + 2;
	$(ed).trigger('input');
});
