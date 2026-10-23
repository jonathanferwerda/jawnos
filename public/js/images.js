// The Gallery: an albums grid, a lazy photo grid, and a full-screen viewer.
//
// Tiles come in pages from /manager/gallery/data; the window itself is a thin
// shell. Nothing here asks the server to build a thumbnail inside the request:
// a stored thumb is served directly, and a missing one answers with a
// placeholder while one generation runs in the background.
var images = [];
var image_number = 0;
var galleryTargetUuid = '';
var galleryPlaceholder = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

function galleryEl(id) { return document.getElementById(id); }

var gallery = {
	view: 'albums',
	app: '',
	search: '',
	sort: 'desc',
	unlock: '',
	files: null,
	items: [],
	albums: [],
	total: 0,
	offset: 0,
	loading: false,
	locked: 0,
	padlock: 0,
	viewerIndex: -1
};

var gallerySearchTimer = null;
var galleryUnlockKey = 'jawnos_gallery_unlock';

// The token the padlock mints for this window. Keeping it for the tab means a
// reopened gallery still shows the sealed photos while the app padlock is open;
// the server clears the secret when the padlock locks, so a stale copy stops
// working and the window asks again.
function galleryUnlockRemember(token) {
	try {
		if (token) { sessionStorage.setItem(galleryUnlockKey, token); }
		else { sessionStorage.removeItem(galleryUnlockKey); }
	} catch (e) {}
}

function galleryUnlockRecall() {
	try { return sessionStorage.getItem(galleryUnlockKey) || ''; } catch (e) { return ''; }
}

function galleryEscape(value) {
	return String(value == null ? '' : value)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function galleryDay(ms) {
	var date = new Date(Number(ms) || Date.now());
	try {
		return date.toLocaleDateString(undefined, { weekday: 'long', month: 'short', day: 'numeric', year: 'numeric' });
	} catch (e) {
		return date.toDateString();
	}
}

// ---- lazy tiles -------------------------------------------------------------
// loading="lazy" still fetched a whole gallery when the grid lived inside a
// scroll box; observe the real viewport so only what is close to the screen
// asks /file_open for its thumbnail.
var galleryLazyObserver = null;
var galleryLazyPending = false;

function galleryLazyLoad(image) {
	if (!image || !image.getAttribute) { return; }
	var src = image.getAttribute('data-src');
	if (!src) { return; }
	image.setAttribute('src', src);
	image.removeAttribute('data-src');
	// A thumb that is still being generated answers with a 1x1 placeholder. Ask
	// again in a moment: the generation slot fills one per pass, so without this
	// a cover stayed blank until the gallery was reopened.
	var tries = 0;
	image.onload = function() {
		if (this.naturalWidth > 1 || tries >= 4) { return; }
		var self = this;
		tries++;
		setTimeout(function() { self.src = src + '&retry=' + tries; }, 2500);
	};
}

function galleryLazyStart() {
	var held = document.querySelectorAll('img.gallery_lazy[data-src]');
	if (!held.length) { return; }
	if (!('IntersectionObserver' in window)) {
		Array.prototype.forEach.call(held, galleryLazyLoad);
		return;
	}
	if (!galleryLazyObserver) {
		galleryLazyObserver = new IntersectionObserver(function(entries) {
			entries.forEach(function(entry) {
				if (!entry.isIntersecting) { return; }
				galleryLazyLoad(entry.target);
				galleryLazyObserver.unobserve(entry.target);
			});
		}, { root: null, rootMargin: '300px' });
	}
	Array.prototype.forEach.call(held, function(image) { galleryLazyObserver.observe(image); });
}

function galleryLazyQueue() {
	if (galleryLazyPending) { return; }
	galleryLazyPending = true;
	setTimeout(function() { galleryLazyPending = false; galleryLazyStart(); }, 120);
}

$(document).ready(function() {
	galleryLazyStart();
	if (window.MutationObserver) {
		new MutationObserver(galleryLazyQueue).observe(document.body, { childList: true, subtree: true });
	}
});

// ---- window and data --------------------------------------------------------

function galleryApplyChrome() {
	$('#gallery_home_tab').toggleClass('active', gallery.view == 'albums');
	$('#gallery_all_tab').toggleClass('active', gallery.view == 'grid' && !gallery.app);
	$('#gallery_sort').text(gallery.sort == 'asc' ? jawnosT('Oldest first') : jawnosT('Newest first'));
	var shut = !(gallery.unlock || '');
	$('#gallery_lock_button').text(shut ? jawnosT('Unlock') : jawnosT('Lock')).attr('hint', shut ? 'Unlock' : 'Lock');
	if ($('#gallery_search').val() != gallery.search) { $('#gallery_search').val(gallery.search); }
}

function galleryInitWindow(response) {
	var attr = $('#gallery').attr('unlock') || '';
	gallery.unlock = (response && typeof response.unlock == 'string' && response.unlock)
		? response.unlock
		: (attr || gallery.unlock || galleryUnlockRecall() || '');
	gallery.padlock = $('#gallery').attr('padlock') == '1' ? 1 : 0;
	if (attr) { galleryUnlockRemember(attr); }
	// A visible album is theirs to browse without a print; the gate opens when
	// they ask for the hidden ones (the Lock button), not on every open.
	if (gallery.unlock) { $('#gallery_lock').hide(); }
	galleryApplyChrome();
}

function imageViewer(data) {
	data = data || {};
	if (data.files) {
		gallery.files = data.files;
		gallery.view = 'grid';
		gallery.app = '';
	}
	if (typeof data.unlock == 'string' && data.unlock) { gallery.unlock = data.unlock; }
	if (data.file_uuid) { galleryTargetUuid = data.file_uuid; }
	if (data.view === 'padlock') {
		$('#gallery_lock').show();
	}
	if (galleryEl('gallery') && !galleryEl('gallery_grid')) {
		// a window rendered by the old gallery; replace it with this shell
		var stale = $('#gallery').closest('.wind');
		if (stale.length) {
			var stale_id = stale.attr('id') || '';
			if (/^window_/.test(stale_id)) { closeWindow(stale_id.replace('window_', '')); }
			else { stale.remove(); }
		}
	}
	if (galleryEl('gallery')) {
		gallery.unlock = $('#gallery').attr('unlock') || gallery.unlock || '';
		galleryInitWindow(null);
		galleryFetch(true);
		return;
	}
	$.ajax({
		url: '/manager/gallery',
		type: 'GET',
		data: { timestamp: timestamp, unlock: gallery.unlock || '', user_agent: navigator.userAgent },
		success: function(response) {
			if (!response || !response.window) { return; }
			windowMaker(response.window);
			galleryInitWindow(response);
			galleryFetch(true);
		}
	});
}

function galleryFetch(reset) {
	if (gallery.loading) {
		// a request is in flight: remember that another is wanted instead of
		// dropping it (a Lock press right after opening would otherwise be lost)
		gallery.queued = reset ? 1 : (gallery.queued || 0);
		return;
	}
	if (reset) {
		gallery.offset = 0;
		gallery.items = [];
	}
	gallery.loading = true;
	$('#gallery_body').css('cursor', 'progress');
	$.ajax({
		url: '/manager/gallery/data',
		type: 'GET',
		data: {
			offset: gallery.offset,
			limit: 160,
			sort: gallery.sort,
			search: gallery.search,
			unlock: gallery.unlock || '',
			apps: gallery.app ? JSON.stringify([gallery.app]) : '',
			files: gallery.files ? JSON.stringify(gallery.files) : ''
		},
		success: function(response) {
			gallery.loading = false;
			$('#gallery_body').css('cursor', '');
			if (!response) { return; }
			gallery.locked = response.locked ? 1 : 0;
			if (typeof response.unlock == 'string' && response.unlock) {
				gallery.unlock = response.unlock;
				$('#gallery').attr('unlock', response.unlock);
				galleryUnlockRemember(response.unlock);
			}
			else if (gallery.locked) {
				// the padlock closed: a remembered token is no longer proof
				gallery.unlock = '';
				galleryUnlockRemember('');
				$('#gallery').attr('unlock', '');
			}
			gallery.albums = response.albums || [];
			gallery.total = response.total || 0;
			if (reset) { gallery.items = response.items || []; }
			else { gallery.items = gallery.items.concat(response.items || []); }
			gallery.offset = gallery.items.length;
			images = gallery.items;
			galleryRender();
			if (galleryTargetUuid) {
				var chosen = -1;
				for (var i = 0; i < gallery.items.length; i++) {
					if (gallery.items[i] && gallery.items[i].uuid == galleryTargetUuid) { chosen = i; break; }
				}
				galleryTargetUuid = '';
				if (chosen > -1) { galleryOpenViewer(chosen); }
			}
			if (gallery.queued) {
				var queued = gallery.queued;
				gallery.queued = 0;
				galleryFetch(queued === 1);
			}
		},
		error: function() {
			gallery.loading = false;
			$('#gallery_body').css('cursor', '');
			if (gallery.queued) {
				var queued = gallery.queued;
				gallery.queued = 0;
				galleryFetch(queued === 1);
			}
		}
	});
}

// ---- rendering --------------------------------------------------------------

function galleryRender() {
	galleryApplyChrome();
	$('#gallery_albums').toggle(gallery.view == 'albums');
	$('#gallery_grid').toggle(gallery.view == 'grid');
	if (gallery.view == 'albums') { galleryRenderAlbums(); }
	else { galleryRenderGrid(); }
	var empty = (gallery.view == 'albums') ? gallery.albums.length == 0 : gallery.items.length == 0;
	$('#gallery_empty').toggle(empty);
	if (!empty && gallery.view == 'grid' && gallery.items.length < gallery.total) {
		$('#gallery_grid').append('<div id="gallery_more" style="grid-column:1/-1;text-align:center;padding:14px;color:#888;font-size:12px;">' + jawnosT('Loading…') + '</div>');
	}
	galleryLazyStart();
}

function galleryRenderAlbums() {
	var html = '';
	gallery.albums.forEach(function(album) {
		html += '<div class="gallery_album_card" data-app="' + galleryEscape(album.app) + '">'
			+ '<img class="gallery_lazy" src="' + galleryPlaceholder + '" data-src="' + galleryEscape(album.cover || '') + '" alt="">'
			+ '<div class="gallery_album_meta"><div class="gallery_album_name">' + galleryEscape(album.label || album.app) + '</div>'
			+ '<div class="gallery_album_count">' + album.count + ' ' + (album.count == 1 ? jawnosT('photo') : jawnosT('photos')) + '</div></div>'
			+ '</div>';
	});
	$('#gallery_albums').html(html);
}

function galleryRenderGrid() {
	var html = '';
	var last_day = '';
	gallery.items.forEach(function(item, index) {
		var day = galleryDay(item.server_time);
		if (day != last_day) {
			html += '<div class="gallery_day">' + galleryEscape(day) + '</div>';
			last_day = day;
		}
		html += '<div class="gallery_tile" data-index="' + index + '">'
			+ '<img class="gallery_lazy" src="' + galleryPlaceholder + '" data-src="' + galleryEscape(item.thumb) + '" alt="' + galleryEscape(item.name) + '">'
			+ (item.type == 'video' ? '<span class="gallery_tile_badge">' + jawnosT('Video') + '</span>' : '')
			+ '</div>';
	});
	$('#gallery_grid').html(html);
}

// ---- viewer -----------------------------------------------------------------

function galleryOpenViewer(index) {
	if (!gallery.items.length) { return; }
	if (index < 0) { index = gallery.items.length - 1; }
	if (index >= gallery.items.length) { index = 0; }
	gallery.viewerIndex = index;
	image_number = index;
	var item = gallery.items[index];
	var stage = $('#gallery_viewer_stage');
	if (item.type == 'video') {
		stage.html('<video src="' + galleryEscape(item.file) + '" controls autoplay loop playsinline></video>');
	}
	else {
		stage.html('<img src="' + galleryEscape(item.file) + '" alt="">');
	}
	$('#gallery_viewer_label').text((item.label || item.app) + ' · ' + galleryDay(item.server_time) + ' · ' + item.name);
	$('.gallery_delete').removeClass('armed').text(jawnosT('Delete'));
	$('.gallery_main').removeClass('armed').text(jawnosT('Set as main image'));
	// Fetch home is the archive's way back: it only means anything for a photo
	// that lives on another machine. A local photo hid nothing to fetch.
	$('.gallery_fetch').toggle(!!item.remote_uuid);
	$('#gallery_viewer').show();
	// measured after it is shown: a hidden element reports a zero rect, which
	// would pad the buttons by the whole taskbar every time
	galleryViewerPad();
	$('#gallery_body').css('overflow', 'hidden');
	galleryFullscreenLabel();
}

// The manager's taskbar is fixed over the page, so a window that reaches the top
// of the screen puts the viewer's buttons underneath it. Push them down by
// whatever overlap there actually is - none, for a window already below it.
function galleryViewerPad() {
	var viewer = document.getElementById('gallery_viewer');
	if (!viewer) { return; }
	if ($('#gallery').hasClass('gallery_fullscreen')) {
		// it covers the desk, taskbar and all: nothing is over it
		viewer.style.setProperty('--gallery_viewer_pad', '6px');
		return;
	}
	var top = viewer.getBoundingClientRect().top;
	// the taskbar is the usual top bar; the clothesline header is fixed too and
	// is what a window with a bottom taskbar sits under
	var bottom = 0;
	['taskbar', 'header'].forEach(function(id) {
		var el = document.getElementById(id);
		if (!el) { return; }
		var r = el.getBoundingClientRect();
		if (r.height > 0 && r.width > window.innerWidth / 2) { bottom = Math.max(bottom, r.bottom); }
	});
	var pad = Math.max(6, Math.ceil(bottom - top) + 6);
	viewer.style.setProperty('--gallery_viewer_pad', pad + 'px');
}

function galleryFullscreenLabel() {
	var on = $('#gallery').hasClass('gallery_fullscreen');
	$('#gallery_viewer_full').text(on ? '⤡' : '⤢').attr('hint', on ? 'Leave full screen' : 'Full screen');
}

function galleryFullscreenToggle() {
	var el = $('#gallery');
	if (!el.length) { return; }
	el.toggleClass('gallery_fullscreen');
	galleryViewerPad();
	galleryFullscreenLabel();
}

function galleryCloseViewer() {
	gallery.viewerIndex = -1;
	$('#gallery_viewer_stage').empty();
	$('#gallery').removeClass('gallery_fullscreen');
	$('#gallery_viewer').hide();
	$('#gallery_body').css('overflow-y', 'auto');
}

function galleryViewerStep(direction) {
	if (gallery.viewerIndex < 0) { return; }
	galleryOpenViewer(gallery.viewerIndex + direction);
}

function galleryImageDisplayer() {
	if (gallery.viewerIndex >= 0) { galleryOpenViewer(image_number); }
}

function imageDiscover() {
	galleryOpenViewer(image_number);
}

// ---- actions ----------------------------------------------------------------

function galleryCurrent() {
	return gallery.items[gallery.viewerIndex] || null;
}

$(document).on('click', '.gallery_info', function() {
	var item = galleryCurrent();
	if (!item) { return; }
	var anchor = $('#gallery_info_anchor');
	anchor.attr({ file: item.f, app: item.app, app_uuid: item.app_uuid, file_uuid: item.uuid });
	anchor.trigger('click');
});

$(document).on('click', '.gallery_main', function() {
	var item = galleryCurrent();
	if (!item) { return; }
	var button = $(this);
	settingSetter({ app: item.app, setting: 'main_image', value: item.f });
	button.text(jawnosT('Main image set'));
	setTimeout(function() { button.text(jawnosT('Set as main image')); }, 1600);
});

$(document).on('click', '.gallery_fetch', function() {
	var item = galleryCurrent();
	if (!item || !item.remote_uuid || !item.f) { return; }
	$.post('/manager/folders/archive/fetch', { path: item.f, remote_uuid: item.remote_uuid });
	var button = $(this);
	button.text(jawnosT('Fetching…'));
	setTimeout(function() { button.text(jawnosT('Fetch home')); }, 1600);
});

$(document).on('click', '.gallery_delete', function() {
	var item = galleryCurrent();
	if (!item) { return; }
	var button = $(this);
	if (!button.hasClass('armed')) {
		button.addClass('armed').text(jawnosT('Tap again to delete'));
		setTimeout(function() { button.removeClass('armed').text(jawnosT('Delete')); }, 2400);
		return;
	}
	button.removeClass('armed').text(jawnosT('Deleting…')).prop('disabled', true);
	$.ajax({
		url: '/manager/delete_file',
		type: 'POST',
		data: { app_uuid: item.app_uuid, file_uuid: item.uuid, app: item.app },
		success: function() {
			var index = gallery.viewerIndex;
			gallery.items.splice(index, 1);
			images = gallery.items;
			gallery.total = Math.max(0, gallery.total - 1);
			gallery.offset = gallery.items.length;
			galleryCloseViewer();
			galleryRender();
			button.prop('disabled', false).text(jawnosT('Delete'));
		},
		error: function() {
			button.prop('disabled', false).text(jawnosT('Delete'));
		}
	});
});

$(document).on('click', '#gallery_viewer_close', galleryCloseViewer);
$(document).on('click', '#gallery_viewer_full', galleryFullscreenToggle);
$(window).on('resize', function() { if ($('#gallery_viewer').is(':visible')) { galleryViewerPad(); } });
$(document).on('click', '#gallery_viewer_prev', function() { galleryViewerStep(-1); });
$(document).on('click', '#gallery_viewer_next', function() { galleryViewerStep(1); });

$(document).on('keydown', function(e) {
	if ($('#gallery_viewer').is(':visible')) {
		if (e.keyCode == 27) { galleryCloseViewer(); }
		if (e.keyCode == 37) { galleryViewerStep(-1); }
		if (e.keyCode == 39) { galleryViewerStep(1); }
	}
});

var galleryTouchStart = null;
var galleryWheelAt = 0;
var galleryWheelAcc = 0;
// A trackpad swipe arrives as a horizontal wheel. Step once per gesture rather
// than once per event, and only when the motion is mostly sideways.
$(document).on('wheel', '#gallery_viewer_stage', function(e) {
	var ev = e.originalEvent || e;
	var dx = ev.deltaX || 0;
	var dy = ev.deltaY || 0;
	if (Math.abs(dx) <= Math.abs(dy)) { return; }
	e.preventDefault();
	var now = Date.now();
	if (now - galleryWheelAt < 400) { return; }
	galleryWheelAcc += dx;
	if (Math.abs(galleryWheelAcc) < 60) { return; }
	galleryViewerStep(galleryWheelAcc > 0 ? 1 : -1);
	galleryWheelAcc = 0;
	galleryWheelAt = now;
});
$(document).on('touchstart', '#gallery_viewer_stage', function(e) {
	var touch = e.originalEvent && e.originalEvent.touches ? e.originalEvent.touches[0] : null;
	galleryTouchStart = touch ? touch.clientX : null;
});
$(document).on('touchend', '#gallery_viewer_stage', function(e) {
	if (galleryTouchStart === null) { return; }
	var touch = e.originalEvent && e.originalEvent.changedTouches ? e.originalEvent.changedTouches[0] : null;
	var end = touch ? touch.clientX : galleryTouchStart;
	var dx = end - galleryTouchStart;
	galleryTouchStart = null;
	if (Math.abs(dx) > 50) { galleryViewerStep(dx > 0 ? -1 : 1); }
});

// ---- navigation -------------------------------------------------------------

$(document).on('click', '#gallery_home_tab', function() {
	gallery.view = 'albums';
	gallery.app = '';
	gallery.files = null;
	// refetch: the album list in the last response was narrowed to the album
	// that was open, so rendering it again would show only that one
	galleryFetch(true);
	$('#gallery_body').scrollTop(0);
});

$(document).on('click', '#gallery_all_tab', function() {
	gallery.view = 'grid';
	gallery.app = '';
	gallery.files = null;
	galleryFetch(true);
	$('#gallery_body').scrollTop(0);
});

$(document).on('click', '#gallery_sort', function() {
	gallery.sort = gallery.sort == 'asc' ? 'desc' : 'asc';
	galleryFetch(true);
});

$(document).on('input', '#gallery_search', function() {
	var value = $(this).val();
	gallery.search = value;
	gallery.app = '';
	gallery.view = 'grid';
	gallery.files = null;
	clearTimeout(gallerySearchTimer);
	gallerySearchTimer = setTimeout(function() { galleryFetch(true); }, 300);
});

$(document).on('keyup', '#gallery_search', function(e) {
	if (e.keyCode == 13) {
		clearTimeout(gallerySearchTimer);
		galleryFetch(true);
	}
});

$(document).on('click', '.gallery_album_card', function() {
	gallery.app = $(this).attr('data-app') || '';
	gallery.view = 'grid';
	gallery.files = null;
	galleryFetch(true);
	$('#gallery_body').scrollTop(0);
});

$(document).on('click', '.gallery_tile', function() {
	var index = parseInt($(this).attr('data-index'), 10);
	if (!isNaN(index)) { galleryOpenViewer(index); }
});

$(document).on('click', '.gallery_lock', function() {
	// One button, two directions: shut, it asks for the print; open, it closes
	// the album that was unlocked and refetches without the token.
	if ($('#gallery').attr('unlock')) {
		galleryUnlockRemember('');
		$('#gallery').attr('unlock', '');
		gallery.unlock = '';
		$('#gallery_lock').hide();
		galleryFetch(true);
		return;
	}
	$('#gallery_lock').show();
	if (typeof padlockAskPhone === 'function') { padlockAskPhone('gallery'); }
});

$(document).on('click', '#gallery_lock_close', function() {
	$('#gallery_lock').hide();
});

// more tiles as the grid nears the bottom
$(document).on('scroll', '#gallery_body', function() {
	if (gallery.view != 'grid' || gallery.loading) { return; }
	var body = this;
	if (body.scrollTop + body.clientHeight >= body.scrollHeight - 400) {
		if (gallery.items.length < gallery.total) { galleryFetch(false); }
	}
});

// The start-menu button opens the Gallery in the albums view.
$(document).on('click', '#image_toggle', function() {
	imageViewer({ view: 'load' });
});

// ---- file information (shared with the rest of the manager) -----------------

$(document).on('click', '.file_information_grabber', function() {
	fileInformationGrabber($(this));
});

function fileInformationGrabber(ig) {
	var file = ig.attr('file');
	var app = ig.attr('app');
	var mouse = JSON.stringify(mouse_position());
	var app_uuid = ig.attr('app_uuid');
	var file_uuid = ig.attr('file_uuid');
	var scope = localStorage.getItem('scope');
	$.ajax({
		url: '/manager/file/information',
		type: 'GET',
		data: { file: file, app: app, mouse: mouse, app_uuid: app_uuid, file_uuid: file_uuid, scope: scope, timestamp: timestamp },
		success: function(response) {
			ig.closest('.wind').append(response.html);
			var info = $('#file_information_' + response.uuid);
			if ((numeral(info.css('left')).value() + info.width()) > $(window).width()) {
				info.css({ 'left': ($(window).width() - info.width() - 5) + 'px' });
			}
			else if (numeral(info.css('left')).value() < 0) {
				info.css({ 'left': '5px' });
			}
			if ((numeral(info.css('top')).value() + info.height()) > $(window).height()) {
				info.css({ 'top': ($(window).height() - info.height() - 5) + 'px' });
			}
			appointment_chron();
		}
	});
}

// Kept for the folders/ide handover: a raw list of files opens the grid.
$(document).on('click', '.image_fetch_home', function() {
	var item = images[image_number] || {};
	if (!item['remote_uuid'] || !item['f']) { return; }
	$.ajax({
		url: '/manager/folders/archive/fetch',
		type: 'POST',
		data: { path: item['f'], remote_uuid: item['remote_uuid'] }
	});
});
