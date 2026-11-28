// Model pickers: a native <select> becomes a button that opens a panel of
// providers, each an accordion section listing its models. A provider can hold
// many models (Alibaba alone has a long list), so the panel opens on the current
// model's provider and the rest stay folded. The select is the source of truth:
// choosing a row sets its value and fires `change`, so every existing saver and
// every Test button keeps working. Enhancement is progressive - without this
// script the select is an ordinary dropdown.
( function () {
	var OPEN = null;

	function textOf(node) {
		return node ? (node.textContent || node.text || '').replace(/\s+/g, ' ').trim() : '';
	}

	function labelOf(select) {
		var option = select.options[select.selectedIndex];
		return textOf(option) || select.getAttribute('data-empty-label') || 'Choose a model';
	}

	function sync(select, button) {
		var label = labelOf(select);
		button.querySelector('.model_picker_label').textContent = label;
		button.title = label;
	}

	function close() {
		if (!OPEN) { return; }
		var open = OPEN;
		OPEN = null;
		open.panel.remove();
		open.button.setAttribute('aria-expanded', 'false');
	}

	function place() {
		if (!OPEN) { return; }
		var panel = OPEN.panel;
		var button = OPEN.button;
		if (!document.documentElement.contains(button)) { close(); return; }
		var r = button.getBoundingClientRect();
		var vw = document.documentElement.clientWidth || window.innerWidth;
		var vh = document.documentElement.clientHeight || window.innerHeight;
		var margin = 8;
		var width = Math.min(Math.max(r.width, 280), vw - margin * 2);
		panel.style.width = width + 'px';
		panel.style.left = Math.max(margin, Math.min(r.left, vw - width - margin)) + 'px';
		panel.style.maxHeight = Math.max(180, Math.min(460, vh - margin * 2)) + 'px';
		var ph = panel.getBoundingClientRect().height;
		var below = r.bottom + 4;
		var above = r.top - 4 - ph;
		if (below + ph <= vh - margin) { panel.style.top = below + 'px'; }
		else if (above >= margin) { panel.style.top = above + 'px'; }
		else { panel.style.top = Math.max(margin, Math.min(below, vh - ph - margin)) + 'px'; }
	}

	// The select's options, in provider sections. A loose option (one the server
	// did not put in an optgroup: "none", "Default model", a kept model) leads as
	// its own section so it is never lost.
	function sectionsOf(select) {
		var loose = [];
		var sections = [];
		Array.prototype.forEach.call(select.children, function (node) {
			if (node.tagName === 'OPTGROUP') {
				sections.push({ label: node.label || 'Models', options: Array.prototype.slice.call(node.querySelectorAll('option')) });
			}
			else if (node.tagName === 'OPTION') {
				loose.push(node);
			}
		});
		if (loose.length) {
			sections.unshift({ label: select.getAttribute('data-loose-label') || 'General', options: loose });
		}
		return sections;
	}

	function choose(select, button, option) {
		if (select.value !== option.value) {
			select.value = option.value;
			select.dispatchEvent(new Event('change', { bubbles: true }));
		}
		sync(select, button);
		close();
		button.focus();
	}

	function open(select, button) {
		close();
		var panel = document.createElement('div');
		panel.className = 'model_picker_panel';
		panel.setAttribute('role', 'listbox');
		var current = select.value;
		var opened = false;
		sectionsOf(select).forEach(function (section) {
			if (!section.options.length) { return; }
			var group = document.createElement('div');
			group.className = 'model_picker_group';
			var head = document.createElement('button');
			head.type = 'button';
			head.className = 'model_picker_group_head';
			head.setAttribute('aria-expanded', 'false');
			var caret = document.createElement('span');
			caret.className = 'model_picker_caret';
			caret.textContent = '\u25b8';
			var headLabel = document.createElement('span');
			headLabel.className = 'model_picker_group_label';
			headLabel.textContent = section.label;
			var count = document.createElement('span');
			count.className = 'model_picker_group_count';
			count.textContent = String(section.options.length);
			head.appendChild(caret);
			head.appendChild(headLabel);
			head.appendChild(count);
			var body = document.createElement('div');
			body.className = 'model_picker_group_body';
			var hasCurrent = false;
			section.options.forEach(function (option) {
				var item = document.createElement('button');
				item.type = 'button';
				item.className = 'model_picker_item';
				item.setAttribute('role', 'option');
				if (option.value === current) {
					item.classList.add('selected');
					item.setAttribute('aria-selected', 'true');
					hasCurrent = true;
				}
				item.textContent = textOf(option) || option.value || '\u2014';
				item.title = item.textContent;
				item.addEventListener('click', function () { choose(select, button, option); });
				body.appendChild(item);
			});
			head.addEventListener('click', function () {
				var nowOpen = group.classList.toggle('open');
				head.setAttribute('aria-expanded', nowOpen ? 'true' : 'false');
			});
			// The current model's provider opens; with nothing chosen the first
			// section opens so the panel is never a row of closed headings.
			if (hasCurrent || (!opened && !current)) {
				group.classList.add('open');
				head.setAttribute('aria-expanded', 'true');
				opened = true;
			}
			group.appendChild(head);
			group.appendChild(body);
			panel.appendChild(group);
		});
		document.body.appendChild(panel);
		button.setAttribute('aria-expanded', 'true');
		OPEN = { select: select, button: button, panel: panel };
		place();
		var chosen = panel.querySelector('.model_picker_item.selected');
		if (chosen && chosen.scrollIntoView) { chosen.scrollIntoView({ block: 'nearest' }); }
	}

	function enhance(select) {
		if (!select || select.getAttribute('data-model-picker') === 'yes') { return; }
		select.setAttribute('data-model-picker', 'yes');
		select.classList.add('model_picker_native');
		var button = document.createElement('button');
		button.type = 'button';
		button.className = 'model_picker_button';
		button.setAttribute('aria-haspopup', 'listbox');
		button.setAttribute('aria-expanded', 'false');
		var hint = select.getAttribute('hint') || select.getAttribute('aria-label') || '';
		if (!hint && select.id) {
			var forLabel = document.querySelector('label[for="' + select.id + '"]');
			if (forLabel) { hint = textOf(forLabel); }
		}
		button.setAttribute('aria-label', hint || 'Choose a model');
		var label = document.createElement('span');
		label.className = 'model_picker_label';
		button.appendChild(label);
		select.parentNode.insertBefore(button, select.nextSibling);
		sync(select, button);
		button.addEventListener('click', function (e) {
			e.preventDefault();
			if (OPEN && OPEN.select === select) { close(); return; }
			open(select, button);
		});
		select.addEventListener('change', function () {
			sync(select, button);
			if (OPEN && OPEN.select === select) { close(); }
		});
	}

	function scan(root) {
		var scope = root && root.querySelectorAll ? root : document;
		var found = [];
		if (scope !== document && scope.matches && scope.matches('select.jawnos_model_select')) { found.push(scope); }
		if (scope.querySelectorAll) {
			var inside = scope.querySelectorAll('select.jawnos_model_select');
			for (var i = 0; i < inside.length; i++) { found.push(inside[i]); }
		}
		for (var j = 0; j < found.length; j++) { enhance(found[j]); }
	}

	document.addEventListener('mousedown', function (e) {
		if (!OPEN) { return; }
		if (OPEN.panel.contains(e.target) || OPEN.button.contains(e.target)) { return; }
		close();
	}, true);
	document.addEventListener('keydown', function (e) {
		if (e.key === 'Escape' && OPEN) {
			var button = OPEN.button;
			close();
			button.focus();
		}
	});
	window.addEventListener('resize', function () { if (OPEN) { place(); } });
	window.addEventListener('scroll', function () { if (OPEN) { place(); } }, true);

	function boot() {
		scan(document);
		if (!window.MutationObserver) { return; }
		var mo = new MutationObserver(function (records) {
			for (var i = 0; i < records.length; i++) {
				var added = records[i].addedNodes || [];
				for (var j = 0; j < added.length; j++) {
					var node = added[j];
					if (node.nodeType !== 1) { continue; }
					if ((node.matches && node.matches('select.jawnos_model_select')) ||
						(node.querySelector && node.querySelector('select.jawnos_model_select'))) {
						scan(node);
					}
				}
			}
		});
		mo.observe(document.body, { childList: true, subtree: true });
	}

	if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', boot); }
	else { boot(); }

	window.jawnosModelPickerScan = scan;
} )();
