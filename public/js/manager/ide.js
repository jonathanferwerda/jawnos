var ide = {};

var ideSearchTimeout;

// Which folders are unfolded. This is the single source of truth for the tree's
// shape: a row is visible when every folder above it is open. It is mirrored in
// the ide's open_folders setting so the tree returns as it was left, and a
// folder's children are fetched only when it first unfolds.
var ideOpen = {};
var ideSearchActive = false;

function ideOpenInit(list) {
	ideOpen = {};
	if (list && list.length) {
		for (var i = 0; i < list.length; i++) { ideOpen[list[i]] = true; }
	}
}

function ideRowVisible(location) {
	if (ideSearchActive || !location) { return true; }
	var parent = $('.ide_file[type="folder"][file="' + location + '"]');
	if (parent.length < 1) { return true; }
	if (!ideOpen[location]) { return false; }
	return ideRowVisible(parent.attr('location'));
}

function ideApplyVisibility() {
	if (ideSearchActive) { return; }
	$('.ide_file').each(function() {
		var row = $(this);
		if (ideRowVisible(row.attr('location'))) { row.show(); }
		else { row.hide(); }
	});
}

function ideFolderSet(file, status, quiet) {
	if (status == 'open') { ideOpen[file] = true; }
	else { delete ideOpen[file]; }
	ideApplyVisibility();
	if (!quiet) {
		$.ajax({
			url: '/manager/ide/folder_toggle',
			type: 'POST',
			data: { folder: file, status: status, timestamp: Date.now() }
		});
	}
}

function ideFolderExpand(sel, quiet, done) {
	var file = sel.attr('file');
	sel.attr('status', 'open');
	idecwd = file;
	ideFolderSet(file, 'open', quiet);
	if (sel.attr('loaded') == 'yes' || $('.ide_file[location="' + file + '"]').length > 0) {
		sel.attr('loaded', 'yes');
		ideApplyVisibility();
		if (done) { done(); }
		return;
	}
	$.ajax({
		url: '/manager/ide/folder_open',
		type: 'POST',
		data: { folder: file, timestamp: Date.now() },
		success: function(response) {
			sel.attr('loaded', 'yes');
			if (response && response.html) { sel.after(response.html); }
			ideApplyVisibility();
			if (done) { done(); }
		},
		error: function() { if (done) { done(); } }
	});
}

function ideFolderCollapse(sel, quiet) {
	var file = sel.attr('file');
	var location = sel.attr('location');
	sel.attr('status', 'closed');
	idecwd = location || ideocwd;
	ideFolderSet(file, 'closed', quiet);
}

// Unfold the remembered folders parent-first, so a child's row exists by the
// time its own unfold is asked for.
function ideRestoreFolders() {
	if (ideSearchActive) { return; }
	var list = [];
	for (var k in ideOpen) { list.push(k); }
	list.sort(function(a, b) { return a.length - b.length; });
	(function step(i) {
		if (i >= list.length) { return; }
		var sel = $('.ide_file[type="folder"][file="' + list[i] + '"]');
		if (sel.length < 1 || sel.attr('status') == 'open') { step(i + 1); return; }
		ideFolderExpand(sel, true, function() { step(i + 1); });
	})(0);
}

// one move in: the words and the file they belong to, so the colours and the
// caret can never disagree about what is open
function ideContentSet(text, file) {
	var c = $('#ide_content');
	c.val(text).attr('file', file || '');
	ideCodeRefresh();
}



$(document).on('click', '#ide_toggle', function() {
	ideFolderSelector();
});

$(document).on('click', '#ide_hamburger', function() {
	var il = $('#ide_list');
	var imw = $('#ide_main_window');
	if (il.is(':visible')) {
		il.hide();
		imw.show();
	}
	else {
		il.show();
		imw.hide();
	}
});

$(document).on('click', '.ide_file', function(e) {
	if (!$(e.target).hasClass('ide_file_delete')) { 
		var sel = $(this);
		var file = sel.attr('file');
		var status = sel.attr('status');
		var location = sel.attr('location');
		if (sel.attr('type') == 'folder') {
			if (ideSearchActive) {
				// search already drew the whole matching tree; a folder just folds
				// its branch
				if (status == 'closed') {
					$('.ide_file[location="' + file + '"]').show();
					sel.attr('status','open');
				}
				else {
					$('.ide_file[location="' + file + '"]').hide();
					sel.attr('status','closed');
				}
			}
			else if (status == 'closed') {
				ideFolderExpand(sel);
			}
			else {
				ideFolderCollapse(sel);
			}
		}
		else {
			ideFileOpen({
				sel: sel,
				file: file,
				location: location
			});
		}
	}
});

function ideFileOpen(data) {
	if (!data) { return; }
	var sel = data['sel'];
	var location = data['location'];
	var timestamp = Date.now();
	var file = data['file'];
	$('.ide_sidebar[status="active"]').attr('status', 'closed');
	console.log('ide file open');
	$.ajax({
		url: '/manager/ide/file_open',
		type: 'GET',
		data: { location: location, timestamp: timestamp, file: file },
		success: function(response) {
			console.log(response);
			if (response['open_app']) {
				if (response['files'] && response['open_app'] == 'gallery') {
					image_number = numeral(response['file_number']).value();
					console.log(image_number + ' is the image_number');
					imageViewer({ 'files': response['files'], loadImages: 1, shuffle: 'off' });
				}
			}
			else {
				$('.ide_tab.active').removeClass('active');
				if ($('.ide_tab[file="' + file + '"]').length >= 1) {
					$('.ide_tab[file="' + file + '"]').addClass('active');
				}
				else {
					$('#ide_navbar').append(response['tab']);
				}
				$('#ide_main_window');
				ideContentSet(response.content, response['file']);
				if (sel) {
					sel.attr('status', 'active');
				}
				ide[response['file']] = response;
				settingSetter({ 'app': 'ide', 'setting': 'active_tab', 'value': file });
				$('#ide_list').hide();
				$('#ide_main_window').show();
			}
		}
	});
}

$(document).on('change', '#ide_folder_selector', function() {
	var folder = $(this).val();
	ideFolderSelector(folder);
});

function ideFolderSelector(folder,search) {
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/ide/folder_selector',
		type: 'POST',
		data: { folder: folder, timestamp: timestamp, search: search },
		success: function(response) {
			windowMaker(response.html);
			ideTabPopulator(response);
			ideSearchActive = ($('#ide_search').val() || '') !== '';
			ideOpenInit(response.open_folders);
			ideRestoreFolders();
			$('#ide_list').show();
			$('#ide_main_window').hide();
		}
	});
}

function ideTabPopulator(response) {
	$.each(response.tabs, function(i,v) {
		if (response.settings.active_tab == i) {
			$('.ide_tab[file="' + v.file + '"]').trigger('click');
		}
	});
}

$(document).on('keyup', '#ide_search', function(e) {
	var search = $(this).val();
	var folder = $('#ide_folder_selector').val();
	var timestamp = Date.now();
	clearInterval(ideSearchTimeout);
	if (e.keyCode == 13) {
		ideFolderSelector(folder,search);
		$('#ide_search').focus();

	}
});

$(document).on('click', '.ide_file_delete', function() {

	var b = $(this);
	var armed = b.attr('armed');
	var file = b.attr('file');
	var type = b.attr('type');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/ide/file_delete',
			type: 'POST',
			data: { file: file, type: type },
			success: function(response) {
				if (response.file) {
					$('.ide_close_tab[file="' + file + '"]').trigger('click');
					$('.ide_file[file="' + file + '"]').remove();
				}
			}
		});
	}
	else {
		b.attr('armed', 'yes');
		var bgcolor = b.css('background-color');
		b.css({'background-color': 'red' });
		setTimeout(function() {
			b.css({'background-color': bgcolor });
			b.attr('armed', 'no');			
		},2000);
	}
});


// input, not keyup: a paste belongs to the file just as much as a keystroke,
// and the tab written by the keydown below never sees a keyup of its own
$(document).on('input', '#ide_content', function() {
	var t = $(this).val();
	var file = $(this).attr('file');
	if (typeof ide[file] != "undefined") {
		ide[file]["content"] = t;
	}
});

$(document).on('click', '#ide_new', function() {
	$('#alert').html('<h1>Gonna make a new file!</h1><h4>Folder: ' + idecwd + '</h4><input id="ide_new_file_namer"><button id="ide_new_file_create" class="hover">Create</button><button id="alert_cancel" class="hover">Cancel</button>').show();
});

$(document).on('click', '#ide_new_file_create', function() {
	var file = $('#ide_new_file_namer').val();
	var filename = idecwd + '/' + file;
	var timestamp = Date.now();
	$.ajax({ 
		url: '/manager/ide/file_create',
		type: 'POST',
		data: { filename: filename, timestamp: timestamp },
		success: function(response) {
			$('#alert').hide();
			ideFolderSelector(idecwd);
			var openerAttempts = 0;
			var opener = setInterval(function() {
				openerAttempts++;
				var f = $('.ide_file[location="' + idecwd + '"][file="' + filename + '"]');
				if (f.length > 0) {
					f.trigger('click');
					clearInterval(opener);
				}
				else if (openerAttempts >= 30) {
					// give up after 15s so a file that never renders can't leak an interval
					clearInterval(opener);
				}
			},500);
		}
	});
});

$(document).on('click', '#ide_save', function() {
	var save = $(this);
	var c = $('#ide_content');
	var f = c.attr('file');
	var t = c.val();
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/ide/save',
		type: 'POST',
		data: { timestamp, timestamp, file: f, content: t },
		success: function(response) {
			var cbg = save.css('background-color');
			if (response.status == 'success') {
				save.css({ 'background-color': 'green' });
			}
			setTimeout(function() {
				save.css({ 'background-color': cbg });
			},500);
		}
	});

});

$(document).on('click', '.ide_tab', function(e) {

	var file = $(this).attr('file');
	if ($(e.target).hasClass('ide_close_tab')) {
		return;
	}
	if (typeof ide[file] != "undefined") {
		ideContentSet(ide[file]["content"], ide[file]['file']);
	}
	else {
		$('.ide_file[file="' + file + '"]').trigger('click');
	}
	$('.ide_tab.active').removeClass('active');
	$(this).addClass('active');
	settingSetter({ 'app': 'ide', 'setting': 'active_tab', 'value': file });
});

$(document).on('click', '.ide_close_tab', function(e) {
	var timestamp = Date.now();
	var b = $(this);
	var t = b.closest('.ide_tab');
	var closing_file = t.attr('file');
	if (t.hasClass('active')) {
		t.removeClass('active');
		var p = t.prev();
		if (!p.hasClass('ide_tab')) {
			p = t.next();
		}
		if (p.length >= 1) {
			p.addClass('active');
			ideContentSet(ide[p.attr('file')]["content"], ide[p.attr('file')]['file']);
		}
		else {
			ideContentSet('', '');
		}
	}
	t.remove();
	delete ide[b.attr('file')];
	$.ajax({
		url: '/manager/ide/file_close',
		type: 'POST',
		data: { timestamp: timestamp, file: closing_file },
		success: function(response) {}
	});
});





