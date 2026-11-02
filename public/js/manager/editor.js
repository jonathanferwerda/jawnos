/* The magazine surface.
 *
 * An article is a writing surface, not a rack of placeholders: the body is one
 * contenteditable column whose direct children are its blocks, and anything a
 * person drops on it is read for what it is (a picture, a track, a video, a
 * link, text) instead of being declared beforehand. */

$(document).on('click', '#editor_toggle', function() {
	editorMaker();
});

// The block the toolbar acts on, the block the grip is dragging, and the media
// element a drag started from (a canvas has no pixels in the drag payload, so
// the live node is what can be read).
var editor_selected_block = null;
var editor_grip_block = null;
var editor_drag_block = null;
var editor_dragged_node = null;
var editor_dirty_state = 0;
var editor_bound = 0;
var editor_close_armed = 0;

function editorT(key, fallback) {
	return (typeof jawnosT === 'function') ? jawnosT(key) : fallback;
}

function editorMaker(source) {
	var url = '/manager/editor';
	// a fresh profile has no scope yet; the route defaults it too, but send a
	// value so the first open does not depend on the server's fallback
	var scope = localStorage.getItem('scope') || 'day';
	var timestamp = Date.now();
	var uuid = localStorage.getItem('article_uuid');
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp, scope: scope, article_uuid: uuid },
		success: function(response) {
			windowMaker(response);
			editorInit(source);
		},
		error: function (response) {}
	});
}

function editorInit(source) {
	var area = document.getElementById('editor_content_area');
	var stored = document.getElementById('editor_stored_content');
	if (area) {
		// stored markup is carried as text in a hidden node, never as live DOM:
		// a synced row cannot run anything before it has been through the
		// server's allowlist
		area.innerHTML = (source == 'new' || !stored) ? '' : (stored.textContent || '');
		editorTidy(area);
	}
	editor_bound_once();
	editor_dirty_state = 0;
	// the article looks like itself while it is being written
	var text_colour = document.getElementById('editor_text_colour');
	var background_colour = document.getElementById('editor_background_colour');
	if (area && text_colour && text_colour.value) { area.style.color = text_colour.value; }
	if (area && background_colour && background_colour.value) { area.style.backgroundColor = background_colour.value; }
	// a save reloads the window; carry the confirmation across that reload
	if (localStorage.getItem('editor_saved') === '1') {
		localStorage.removeItem('editor_saved');
		editorSaved();
	}
	else {
		$('#editor_save_state').text('').removeClass('editor_save_dirty editor_save_saved');
	}
	editor_empty_state();
	if (source == 'new') {
		editorAddText();
	}
}

// ---------------------------------------------------------------- block model

function editorArea() {
	return document.getElementById('editor_content_area');
}

// The block a node belongs to: the direct child of the writing surface.
function editorBlockOf(node) {
	var area = editorArea();
	while (node && node !== area && node.parentNode !== area) {
		node = node.parentNode;
	}
	return (node && node !== area && node.parentNode === area) ? node : null;
}

function editorBlocks() {
	var area = editorArea();
	if (!area) { return []; }
	var out = [];
	for (var i = 0; i < area.children.length; i++) { out.push(area.children[i]); }
	return out;
}

// Old articles carry the grapple's classes and a type attribute that the old
// adders wrote. They mean nothing now and would leave stale state in the HTML.
function editorTidy(area) {
	if (!area) { return; }
	var nodes = area.querySelectorAll('*');
	for (var i = 0; i < nodes.length; i++) {
		nodes[i].classList.remove('grapple_active');
		nodes[i].classList.remove('grapple_inactive');
		nodes[i].removeAttribute('type');
	}
	// a bare text node between blocks becomes a paragraph of its own
	var walker = document.createTreeWalker(area, NodeFilter.SHOW_TEXT, null, false);
	var strays = [];
	while (walker.nextNode()) {
		var text = walker.currentNode;
		if (text.parentNode === area && text.nodeValue.trim().length) { strays.push(text); }
	}
	strays.forEach(function(text) {
		var p = document.createElement('p');
		p.textContent = text.nodeValue;
		area.replaceChild(p, text);
	});
	editorEmptyState();
}

function editorEmptyState() {
	var area = editorArea();
	if (!area) { return; }
	var has = false;
	for (var i = 0; i < area.children.length; i++) {
		var child = area.children[i];
		if (child.tagName === 'BR') { continue; }
		if (child.tagName === 'HR' || child.textContent.trim().length || child.querySelector('img,video,audio')) { has = true; break; }
	}
	area.classList.toggle('editor_is_empty', !has);
}

// ---------------------------------------------------------------- insertion

// A collapsed range where the pointer is, for a drop or a click inside the page.
function editorRangeAt(x, y) {
	var area = editorArea();
	var range = null;
	if (typeof x !== 'number' || typeof y !== 'number') {
		// a paste has no pointer: it lands where the caret is
		var sel = window.getSelection();
		if (sel && sel.rangeCount) { range = sel.getRangeAt(0); }
	}
	else if (document.caretRangeFromPoint) {
		range = document.caretRangeFromPoint(x, y);
	}
	else if (document.caretPositionFromPoint) {
		var pos = document.caretPositionFromPoint(x, y);
		if (pos) {
			range = document.createRange();
			range.setStart(pos.offsetNode, pos.offset);
			range.collapse(true);
		}
	}
	if (range && area && area.contains(range.startContainer)) { return range; }
	return null;
}

// Where a new block goes: before or after the block under the pointer, or at
// the end when the pointer is past the last block.
function editorInsertPoint(x, y) {
	var range = editorRangeAt(x, y);
	var block = range ? editorBlockOf(range.startContainer) : null;
	if (!block) { return { block: null, after: true }; }
	var box = block.getBoundingClientRect();
	return { block: block, after: (y > box.top + box.height / 2) };
}

function editorInsert(node, at) {
	var area = editorArea();
	if (!area) { return node; }
	if (at && at.block && at.block.parentNode === area) {
		area.insertBefore(node, at.after ? at.block.nextSibling : at.block);
	}
	else {
		area.appendChild(node);
	}
	editorEmptyState();
	return node;
}

// Put the caret in a block so typing continues where the new block was made.
function editorFocusBlock(block) {
	if (!block) { return; }
	block.focus();
	var range = document.createRange();
	range.selectNodeContents(block);
	range.collapse(false);
	var sel = window.getSelection();
	sel.removeAllRanges();
	sel.addRange(range);
}

function editorAddText(at) {
	var area = editorArea();
	if (!area) { return null; }
	var p = document.createElement('p');
	p.appendChild(document.createElement('br'));
	if (!at) { at = { block: editor_selected_block, after: true }; }
	editorInsert(p, at);
	editorDirty();
	editorFocusBlock(p);
	editor_selected_block = p;
	return p;
}

function editorAddRule(at) {
	var hr = document.createElement('hr');
	editorInsert(hr, at || { block: editor_selected_block, after: true });
	editorDirty();
	return hr;
}

// ---------------------------------------------------------------- block style

function editorSelectBlock(block) {
	editor_selected_block = block;
	$('.editor_style_button').removeClass('editor_style_active');
	if (!block) { return; }
	$('.editor_style_button[data-block="' + block.tagName.toLowerCase() + '"]').addClass('editor_style_active');
}

function editorSetBlockStyle(tag) {
	var area = editorArea();
	var block = editor_selected_block;
	// nothing selected: style the block the caret is in
	if (!block || !area || block.parentNode !== area) {
		var sel = window.getSelection();
		if (sel.rangeCount) { block = editorBlockOf(sel.getRangeAt(0).startContainer); }
	}
	if (!block || block.parentNode !== area) {
		// an empty article has nothing to restyle: make the block being asked for
		if (!editorBlocks().length) {
			block = editorAddText();
			if (block && tag !== 'p') { editorSetBlockStyle(tag); }
			return;
		}
		return;
	}
	if (block.tagName.toLowerCase() === tag) {
		editorSelectBlock(block);
		return;
	}
	var replacement = document.createElement(tag);
	replacement.innerHTML = block.innerHTML;
	block.parentNode.replaceChild(replacement, block);
	editorSelectBlock(replacement);
	editorDirty();
	editorEmptyState();
}

// ---------------------------------------------------------------- media

// Turn a dragged element into something an article can keep. A picture is
// embedded as data so the public homepage can show it without the vault; a
// track or a video keeps its source.
function editorNodeFromElement(el) {
	if (!el || !el.tagName) { return null; }
	var tag = el.tagName.toLowerCase();
	if (tag === 'img') {
		var src = el.getAttribute('src') || '';
		var embedded = editorEmbeddedImage(el);
		var img = document.createElement('img');
		img.className = 'editor_content_component';
		img.setAttribute('src', embedded || src);
		img.setAttribute('alt', el.getAttribute('alt') || '');
		return img;
	}
	if (tag === 'canvas') {
		var canvas = document.createElement('img');
		canvas.className = 'editor_content_component';
		try { canvas.setAttribute('src', el.toDataURL('image/png')); }
		catch (e) { return null; }
		return canvas;
	}
	if (tag === 'video' || tag === 'audio') {
		var media = document.createElement(tag);
		media.className = 'editor_content_component';
		media.setAttribute('src', el.getAttribute('src') || '');
		media.setAttribute('controls', 'controls');
		return media;
	}
	return null;
}

// A picture on another window may be a blob: URL that dies with that window, or
// a thumb that is not the picture. Drawing it through a canvas gives the article
// bytes of its own. A cross-origin picture taints the canvas; then the source is
// kept as it is.
function editorEmbeddedImage(img) {
	try {
		if (!img.complete || !img.naturalWidth) { return null; }
		var canvas = document.createElement('canvas');
		canvas.width = img.naturalWidth;
		canvas.height = img.naturalHeight;
		canvas.getContext('2d').drawImage(img, 0, 0);
		return canvas.toDataURL('image/png');
	}
	catch (e) { return null; }
}

var EDITOR_MEDIA_EXT = /\.(png|jpe?g|gif|webp|avif|bmp|heic|heif|svg|mp4|webm|mov|mkv|avi|mp3|wav|ogg|oga|m4a|flac|aac)(?:[?#]|$)/i;
var EDITOR_VIDEO_EXT = /\.(mp4|webm|mov|mkv|avi|m4v)(?:[?#]|$)/i;
var EDITOR_AUDIO_EXT = /\.(mp3|wav|ogg|oga|m4a|flac|aac|opus)(?:[?#]|$)/i;

// What a dropped URL is, read from the URL itself: no picker, no declared type.
function editorNodeFromUrl(url) {
	if (!url) { return null; }
	var clean = url.replace(/^["']|["']$/g, '');
	if (!EDITOR_MEDIA_EXT.test(clean)) {
		var link = document.createElement('a');
		link.className = 'editor_content_component';
		link.setAttribute('href', clean);
		link.textContent = clean;
		return link;
	}
	if (EDITOR_VIDEO_EXT.test(clean)) {
		var video = document.createElement('video');
		video.className = 'editor_content_component';
		video.setAttribute('src', clean);
		video.setAttribute('controls', 'controls');
		return video;
	}
	if (EDITOR_AUDIO_EXT.test(clean)) {
		var audio = document.createElement('audio');
		audio.className = 'editor_content_component';
		audio.setAttribute('src', clean);
		audio.setAttribute('controls', 'controls');
		return audio;
	}
	var img = document.createElement('img');
	img.className = 'editor_content_component';
	img.setAttribute('src', clean);
	img.setAttribute('alt', '');
	return img;
}

// A picture file from the desktop is shrunk and embedded, so an article stays
// one row the house can sync and the public homepage can draw. Everything else
// is uploaded and linked.
function editorImageFromFile(file, done) {
	var url = URL.createObjectURL(file);
	var image = new Image();
	image.onload = function() {
		var width = image.naturalWidth || 0;
		var height = image.naturalHeight || 0;
		var scale = (width > 1600) ? (1600 / width) : 1;
		var canvas = document.createElement('canvas');
		canvas.width = Math.max(1, Math.round(width * scale));
		canvas.height = Math.max(1, Math.round(height * scale));
		var context = canvas.getContext('2d');
		context.drawImage(image, 0, 0, canvas.width, canvas.height);
		var type = 'image/jpeg';
		// a picture with transparency stays PNG; a photograph does not need it
		try {
			var data = context.getImageData(0, 0, canvas.width, canvas.height).data;
			for (var i = 3; i < data.length; i += 4 * 17) {
				if (data[i] < 250) { type = 'image/png'; break; }
			}
		}
		catch (e) {}
		var data_url = '';
		try { data_url = canvas.toDataURL(type, 0.85); }
		catch (e) { data_url = ''; }
		URL.revokeObjectURL(url);
		if (!data_url) {
			var reader = new FileReader();
			reader.onload = function() { done(reader.result); };
			reader.readAsDataURL(file);
			return;
		}
		done(data_url);
	};
	image.onerror = function() {
		URL.revokeObjectURL(url);
		var reader = new FileReader();
		reader.onload = function() { done(reader.result); };
		reader.readAsDataURL(file);
	};
	image.src = url;
}

function editorUpload(file, done) {
	var form = new FormData();
	form.append('file', file, file.name || ('drop_' + Date.now()));
	form.append('app', 'editor');
	form.append('timestamp', Date.now());
	form.append('duration', '1000');
	$.ajax({
		url: '/manager/upload_file',
		type: 'POST',
		data: form,
		processData: false,
		contentType: false,
		success: function(response) {
			var out = response || {};
			try { out = (typeof out === 'string') ? JSON.parse(out) : out; } catch (e) {}
			done(out);
		},
		error: function() { done({}); }
	});
}

// A file that is not a picture: store it, then link the stored copy.
function editorNodeFromFile(file, at) {
	var kind = (file.type || '').toLowerCase();
	if (kind.indexOf('image/') === 0) {
		editorImageFromFile(file, function(data_url) {
			if (!data_url) { return; }
			var img = document.createElement('img');
			img.className = 'editor_content_component';
			img.setAttribute('src', data_url);
			img.setAttribute('alt', file.name || '');
			editorInsert(img, at);
			editorDirty();
			editorAddText({ block: img, after: true });
		});
		return;
	}
	editorUpload(file, function(response) {
		var stored = [];
		try { stored = JSON.parse(response.file || '[]') || []; } catch (e) {}
		var entry = stored[0] || {};
		var src = (response.urls && response.urls[0]) || entry.url || '';
		if (!src && entry.f && response.uuid) {
			src = '/manager/download_file?app=' + encodeURIComponent(response.app || 'editor')
				+ '&uuid=' + encodeURIComponent(response.uuid)
				+ '&timestamp=' + encodeURIComponent(response.timestamp || '')
				+ '&file=' + encodeURIComponent(entry.f);
		}
		if (!src) { return; }
		var node;
		if (kind.indexOf('video/') === 0) {
			node = document.createElement('video');
			node.setAttribute('controls', 'controls');
			node.setAttribute('src', src);
		}
		else if (kind.indexOf('audio/') === 0) {
			node = document.createElement('audio');
			node.setAttribute('controls', 'controls');
			node.setAttribute('src', src);
		}
		else {
			node = document.createElement('a');
			node.setAttribute('href', src);
			node.textContent = file.name || src;
		}
		node.className = 'editor_content_component';
		editorInsert(node, at);
		editorDirty();
		editorAddText({ block: node, after: true });
	});
}

// The one way anything lands on the page.
function editorInsertTransfer(data, at) {
	var handled = 0;
	// 1. the element the drag started from, if it was media
	if (editor_dragged_node) {
		var node = editorNodeFromElement(editor_dragged_node);
		if (node) {
			editorInsert(node, at);
			handled = 1;
		}
		editor_dragged_node = null;
	}
	// 2. real files, which is what a desktop drop carries
	if (!handled && data.files && data.files.length) {
		for (var i = 0; i < data.files.length; i++) {
			editorNodeFromFile(data.files[i], at);
		}
		handled = 1;
	}
	// 3. a piece of another page: its pictures, or its words
	if (!handled) {
		var html = data.getData ? data.getData('text/html') : '';
		if (html) {
			var template = document.createElement('template');
			template.innerHTML = html;
			var media = template.content.querySelectorAll('img,video,audio,canvas');
			for (var m = 0; m < media.length; m++) {
				var built = editorNodeFromElement(media[m]);
				if (built) {
					editorInsert(built, at);
					handled = 1;
				}
			}
		}
	}
	// 4. a URL, read for what it points at
	if (!handled) {
		var url = (data.getData ? (data.getData('text/uri-list') || '') : '');
		if (!url) { url = (data.getData ? data.getData('text/plain') : '') || ''; }
		if (url && /^(?:https?:|data:|)\/?\S+$/i.test(url.trim()) && url.trim().indexOf('\n') < 0) {
			var from_url = editorNodeFromUrl(url.trim());
			if (from_url) {
				editorInsert(from_url, at);
				handled = 1;
			}
		}
	}
	// 5. words, placed where they were let go
	if (!handled) {
		var text = (data.getData ? data.getData('text/plain') : '') || '';
		if (text) {
			var range = editorRangeAt(at.x, at.y);
			if (range) {
				range.deleteContents();
				range.insertNode(document.createTextNode(text));
			}
			else {
				var p = document.createElement('p');
				p.textContent = text;
				editorInsert(p, at);
			}
			handled = 1;
		}
	}
	if (handled) {
		editorDirty();
		editorEmptyState();
	}
	return handled;
}

// ---------------------------------------------------------------- binding

function editor_bound_once() {
	if (editor_bound) { return; }
	editor_bound = 1;

	// The grip is one floating handle: it never enters the article, so the
	// saved markup carries no editor furniture.
	document.addEventListener('mousemove', function(e) {
		var area = editorArea();
		var grip = document.getElementById('editor_block_grip');
		if (!area || !grip) { return; }
		if (!area.contains(e.target) || e.target === grip) {
			if (!editor_drag_block) { grip.style.display = 'none'; }
			return;
		}
		var block = editorBlockOf(e.target);
		if (!block || block.tagName === 'BR') { return; }
		editor_grip_block = block;
		var area_box = area.getBoundingClientRect();
		var box = block.getBoundingClientRect();
		grip.style.top = (box.top - area_box.top + area.scrollTop + 2) + 'px';
		grip.style.display = 'block';
	});

	document.addEventListener('dragstart', function(e) {
		var grip = e.target.closest ? e.target.closest('#editor_block_grip') : null;
		if (grip) {
			editor_drag_block = editor_grip_block;
			if (e.dataTransfer) { e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', 'editor-block'); }
			return;
		}
		// a picture or a player dragged from another window: remember the live
		// node, because a canvas has no pixels in the payload
		var el = e.target;
		if (el && el.tagName && /^(IMG|CANVAS|VIDEO|AUDIO)$/.test(el.tagName)) {
			editor_dragged_node = el;
		}
	}, true);

	document.addEventListener('dragend', function() {
		editor_drag_block = null;
		editor_dragged_node = null;
	});

	$(document).on('dragover', '#editor_content_parent', function(e) {
		e.preventDefault();
		$(this).addClass('editor_is_dropping');
		if (e.originalEvent && e.originalEvent.dataTransfer) {
			e.originalEvent.dataTransfer.dropEffect = editor_drag_block ? 'move' : 'copy';
		}
	});

	$(document).on('dragleave', '#editor_content_parent', function(e) {
		if (e.target === this) { $(this).removeClass('editor_is_dropping'); }
	});

	$(document).on('drop', '#editor_content_parent', function(e) {
		e.preventDefault();
		$(this).removeClass('editor_is_dropping');
		var event = e.originalEvent || e;
		var at = editorInsertPoint(event.clientX, event.clientY);
		at.x = event.clientX;
		at.y = event.clientY;
		if (editor_drag_block) {
			var moving = editor_drag_block;
			editor_drag_block = null;
			if (!at.block || at.block !== moving) {
				editorInsert(moving, at);
				editorDirty();
			}
			return;
		}
		editorInsertTransfer(event.dataTransfer, at);
	});

	$(document).on('input', '#editor_content_area', function() {
		editorDirty();
		editorEmptyState();
		editorSelectBlock(editorBlockOf(window.getSelection().anchorNode));
	});

	$(document).on('mouseup keyup', '#editor_content_area', function() {
		var sel = window.getSelection();
		if (sel && sel.rangeCount) {
			editorSelectBlock(editorBlockOf(sel.getRangeAt(0).startContainer));
		}
	});

	$(document).on('keydown', '#editor_content_area', function(e) {
		if (!e.altKey) { return; }
		if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') { return; }
		var block = editorBlockOf(window.getSelection().anchorNode);
		if (!block) { return; }
		e.preventDefault();
		if (e.key === 'ArrowUp' && block.previousElementSibling) {
			block.parentNode.insertBefore(block, block.previousElementSibling);
		}
		else if (e.key === 'ArrowDown' && block.nextElementSibling) {
			block.parentNode.insertBefore(block.nextElementSibling, block);
		}
		editorDirty();
		editorFocusBlock(block);
	});

	$(document).on('click', '.editor_style_button', function() {
		editorSetBlockStyle($(this).attr('data-block'));
	});

	$(document).on('click', '#editor_add_text', function() {
		editorAddText();
	});

	$(document).on('click', '#editor_add_divider', function() {
		editorAddRule();
		editorAddText();
	});

	$(document).on('click', '#editor_add_media', function(e) {
		e.preventDefault();
		// a person asked for media but has nothing to drag: hand them the picker
		$('#editor_file_picker').trigger('click');
	});

	$(document).on('change', '#editor_file_picker', function() {
		var files = this.files || [];
		var at = { block: editor_selected_block, after: true };
		for (var i = 0; i < files.length; i++) {
			editorNodeFromFile(files[i], at);
		}
		this.value = '';
	});

	// A pasted picture (a screenshot is the common one) is media; pasted markup
	// is kept as words unless it really is a picture.
	$(document).on('paste', '#editor_content_area', function(e) {
		var event = e.originalEvent || e;
		var data = event.clipboardData;
		if (!data) { return; }
		var files = data.files || [];
		var has_image = 0;
		for (var i = 0; i < files.length; i++) {
			if ((files[i].type || '').indexOf('image/') === 0) { has_image = 1; }
		}
		if (has_image || (data.getData && data.getData('text/html') && /<img/i.test(data.getData('text/html')))) {
			e.preventDefault();
			var sel = window.getSelection();
			var at = { block: null, after: true };
			if (sel && sel.rangeCount) { at.block = editorBlockOf(sel.getRangeAt(0).startContainer); }
			editorInsertTransfer(data, at);
			return;
		}
		if (data.getData && data.getData('text/html')) {
			// words from a web page arrive with colours and fonts; keep the words
			e.preventDefault();
			var text = data.getData('text/plain') || '';
			if (text && document.execCommand) { document.execCommand('insertText', false, text); }
		}
	});

	$(document).on('change input', '#editor_category_picker, #editor_status_picker, #editor_timestamp, #editor_warranty', function () {
		editorDirty();
	});

	$(document).on('change', '#editor_background_colour', function(e) {
		var target = editor_selected_block || editorArea();
		if (target) { $(target).css({ 'background-color': $(this).val() }); }
		editorDirty();
	});

	$(document).on('change', '#editor_text_colour', function(e) {
		var target = editor_selected_block || editorArea();
		if (target) { $(target).css({ 'color': $(this).val() }); }
		editorDirty();
	});

	$(document).on('change', '#editor_article_picker', function() {
		localStorage.setItem('article_uuid', $(this).val());
		editorMaker();
	});

	$(document).on('click', '#editor_new', function() {
		localStorage.setItem('article_uuid', 'none');
		editorMaker('new');
	});

	// The window is closed with its own button, so the unsaved guard has to stand
	// there. A capture listener runs before the window's own handler and can stop
	// it; the second press is the confirmation, which reads the same in every
	// engine as the first.
	document.addEventListener('click', function(e) {
		var button = e.target.closest ? e.target.closest('.close_button[app="editor"]') : null;
		if (!button || !editor_dirty_state) { return; }
		if (editor_close_armed) { return; }
		e.preventDefault();
		e.stopPropagation();
		editor_close_armed = 1;
		$('#editor_save_state')
			.text(editorT('Press close again to discard your changes', 'Press close again to discard your changes'))
			.addClass('editor_save_dirty');
		setTimeout(function() {
			editor_close_armed = 0;
			if (editor_dirty_state) { editorDirty(); }
		}, 3000);
	}, true);

	$(document).on('click', '#editor_save', function() {
		var area = editorArea();
		var content = area ? area.innerHTML : '';
		var headline = area ? area.querySelector('h1, h2, h3') : null;
		var paragraph = area ? area.querySelector('p') : null;
		var picture = area ? area.querySelector('img') : null;
		var title = headline ? headline.textContent.trim() : '';
		if (!title && paragraph) { title = paragraph.textContent.trim().slice(0, 80); }
		if (!title) { title = editorT('Untitled', 'Untitled'); }
		$.ajax({
			url: '/manager/editor/save',
			type: 'POST',
			data: {
				content: content,
				title: title,
				timestamp: $('#editor_timestamp').val(),
				category: $('#editor_category_picker').val(),
				text_colour: $('#editor_text_colour').val(),
				background_colour: $('#editor_background_colour').val(),
				article_uuid: (localStorage.getItem('article_uuid') || 'none'),
				status: $('#editor_status_picker').val(),
				scope: localStorage.getItem('scope'),
				warranty: $('#editor_warranty').val(),
				image: picture ? picture.getAttribute('src') : '',
				teaser: paragraph ? paragraph.textContent : ''
			},
			success: function(response) {
				editor_dirty_state = 0;
				localStorage.setItem('article_uuid', response.uuid);
				localStorage.setItem('editor_saved', '1');
				editorMaker();
			}
		});
	});

	// Delete arms itself and says so in its own label: a red flash was the only
	// clue the old one gave, and it looked the same as a hover.
	$(document).on('click', '#editor_delete', function() {
		var button = $(this);
		var uuid = localStorage.getItem('article_uuid');
		if (!button.attr('armed')) {
			button.attr('armed', 'yes');
			button.attr('data-label', button.text());
			button.text(editorT('Press again to delete', 'Press again to delete'));
			button.addClass('editor_button_danger');
			setTimeout(function() {
				button.removeAttr('armed');
				button.removeClass('editor_button_danger');
				button.text(button.attr('data-label') || editorT('Delete', 'Delete'));
			}, 3000);
			return;
		}
		button.removeAttr('armed');
		$.ajax({
			url: '/manager/editor/delete',
			type: 'POST',
			data: { article_uuid: uuid },
			success: function() {
				editor_dirty_state = 0;
				localStorage.setItem('article_uuid', 'none');
				editorMaker();
			}
		});
	});
}

function editorDirty() {
	editor_dirty_state = 1;
	$('#editor_save_state')
		.text(editorT('Unsaved changes', 'Unsaved changes'))
		.addClass('editor_save_dirty')
		.removeClass('editor_save_saved');
}

function editorSaved() {
	editor_dirty_state = 0;
	$('#editor_save_state')
		.text(editorT('Saved', 'Saved'))
		.addClass('editor_save_saved')
		.removeClass('editor_save_dirty');
}
