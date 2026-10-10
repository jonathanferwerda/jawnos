var folders = {
	selected: [],
	clipboard: [],
	command: undefined,
	folder: undefined,
	disk: {},
	files: [],
	type: undefined,
	path: undefined,
	remote_uuid: undefined
};
// a long press on a file, folder or the listing background opens its menu on touch
if (typeof jawnosContextMenuOn == 'function') { jawnosContextMenuOn('.folders_file, .folders_contents'); }
$(document).on('click', '#folders_toggle', function() {
	foldersOpener();
});

function foldersOpener(data) {
	if (!data) {
		data = {};
	}
	// which machine is being browsed: an explicit choice, else whatever the
	// window was rendered for, else this machine
	if (folders.remote_uuid === undefined) {
		folders.remote_uuid = $('#folders').attr('remote_uuid') || '';
	}
	var remote_uuid = (data['remote_uuid'] !== undefined) ? data['remote_uuid'] : folders.remote_uuid;
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/folders',
		type: 'POST',
		data: { 
			timestamp: timestamp,
			folder: data['folder'],
			command: data['command'],
			remote_uuid: remote_uuid
		},
		success:function(response) {
			windowMaker(response.html);
			folders['folder'] = response.fo.folder;
			folders['disk'] = response.fo.disk;
			folders['files'] = response.fo.files;
			folders['remote_uuid'] = remote_uuid;
			$('#folders_machine_select').val(remote_uuid);
			// a remote listing is read-only, and worth saying so at a glance
			$('#folders_toolbar').css({ 'border-color': remote_uuid ? 'orange' : '' });
			foldersDraggable();
		}
	});
}

$(document).on('change', '#folders_machine_select', function () {
	// a new machine starts at its own home: this machine's paths mean nothing
	// over there
	foldersOpener({ remote_uuid: $(this).val(), folder: '' });
});

function foldersDraggable() {
	if (windowPhoneChecker() == false) {
		$('.folders_file').each(function(i,v) {
			var folder = $(v);
			if (!folder.hasClass('ui-draggable')) {

				folder.draggable({
					appendTo: "body",
					helper: "clone",
					revert: "invalid",
					zIndex: 999999,
					cursorAt: { top: 30, left: 30 },

					cancel: '',
					start: function(p,ui) {
						console.log('started dragging a file/folder');
						$(this).css('opacity', '0');
						if (folders.selected.length > 1) {
						  var badgeHtml = '<div class="number_badge">' + folders.selected.length + '</div>';
						  
						  // Append the badge directly to the temporary clone element
						  ui.helper.append(badgeHtml);
						}
					},
					drag: function(p,ui) {
						console.log('dragging a file/folder');
					  ui.position.left = p.pageX - 30;
					  ui.position.top = p.pageY - 30;
					},
					stop: function(p,ui) {
						$(this).css('opacity', '1');
						console.log('stopped dragging a file/folder');
						


					}
				});
			}
		});
	}
}


$(document).on('click', '.folders_file', function(e) {
	var f = $(this);

	if (!e.ctrlKey) {
		$('.folders_file').removeClass('selected');
	}
	if (e.shiftKey) {

	}

	if (f.hasClass('selected')) {
		f.removeClass('selected');
	} else {
		f.addClass('selected');
		folders.type = f.attr('type');
		folders.path = f.attr('path');
	}
	folderSelection();
});

$(document).on('click contextmenu', '.folders_contents', function(e) {
	if ($(e.target).hasClass('folders_contents')) {
		folders.type = undefined;
		folders.path = undefined;
		$('.folders_file').removeClass('selected');
		folderSelection();
	}
});

$(document).on('dblclick', '.folders_file', function() {
	folders.type = $(this).attr('type');
	folders.path = $(this).attr('path');
	if (folders.type == 'folder') {
		foldersOpener({ folder: folders.path });
	}
	else {
		foldersFileOpener();
	}
});

function foldersFileOpener() {
	var jfolders = JSON.stringify(folders);
	$.ajax({
		url: '/manager/folders/file/open',
		type: 'POST',
		data: { 
			folders: jfolders
		},
		success: function(response) {
			console.log(response);
			if (response['app'] == 'gallery') {
				console.log('loading gallery');
				imageViewer({ 'files': response['files'], loadImages: 1, shuffle: 'off' });
			} else if (response['app'] == 'music') {
				musicToggle(response['raw_files']);
			} else if (response['app'] == 'studio') {
				studioImport(response['files']);
			} else if (response['app'] == 'ide') {
				console.log('this is for the ide');
				$.each(response['raw_files'], function(i,v) {
					console.log('opening ' + v);
					ideFileOpen({
						location: folders['folder'],
						file: v
					});
				});
			}
		}
	});
}

function folderSelection() {
	var selected = [];
	$('.folders_file.selected').each(function(i,v) {
		var p = $(v).attr('path');
		var t = $(v).attr('type');
		var file = {
			path: p,
			type: t
		};
		selected.push(file);
	});
	folders.selected = selected;
}

$(document).on('contextmenu', '.folders_file, .folders_contents', function(e) {
  e.preventDefault();
	// a hold on touch dispatches this same event with the finger's point, so the
	// menu lands under the press rather than wherever the mouse last was
	var press_x = e.clientX, press_y = e.clientY;
	// a remote listing is read-only: every command here would run on this
	// machine against a path that only exists on the other one
	if (folders.remote_uuid) { return; }
	var wind = $(this).closest('.wind');
	var f = $(e.target);
	var context = 'file';
	if (f.hasClass('folders_contents')) {
		folders.path = undefined;
		folders.type = undefined;
		$('.folders_file').removeClass('selected');
		folderSelection();
		context = 'folder_background';
		console.log('clicked the background');

	} else {
		f = f.closest('.folders_file');
		console.log('clicked a file or folder');
		folders.path = f.attr('path');
		folders.type = f.attr('type');
		if (!f.hasClass('selected')) {
			f.addClass('selected');
		}
		if (folders.type == 'folder') {
			context = 'folder';
		}
	}

	console.log('right click');
	folderSelection();
	var jfolders = JSON.stringify(folders);
	$.ajax({
		url: '/manager/folders/context',
		type: 'POST',
		data: { path: folders.path, type: folders.type, folders: jfolders, context: context },
		success:function(response) {
			console.log(response);
			var m = { x: press_x, y: press_y };
			$('#folders_contents').append(response.html);
			var menu = $('.folders_context[uuid="'+ response.call_uuid + '"]');
			menu.css({ 'left': m.x, 'top': m.y, 'position':'fixed' });
			if (numeral(menu.css('right')).value() < numeral(wind.css('right')).value()) {
				menu.css({ 'right': (($(window).width() - m.x)), 'left': '' });
			}
			if (numeral(menu.css('bottom')).value() < numeral(wind.css('bottom')).value()) {
				menu.css({ 'bottom': (($(window).height() - m.y)), 'top': '' });
			}
		}
	});
});

$(document).on('click contextmenu', function(e) {
	$('.folders_context').remove();
});

$(document).on('click', '.folders_command', function() {
	var command = $(this).attr('command');
	var folder = $('#folders').attr('folder');
	foldersOpener({ folder: folder, command: command });
});

$(document).on('keyup', '#folders_address', function(e) {
	var folder = $(this).val();
	if (e.keyCode == 13) {
		foldersOpener({ folder: folder });
	}
});

$(document).on('click','.folders_context_selection', function(e) {
	var command = $(this).attr('command');
	foldersCommand({ command: command });
});

function foldersCommand(data) {
	if (!data) { return; }
	// fetching is the one thing that makes sense while looking at another
	// machine, so it is answered before the read-only gate below
	if (data['command'] == 'fetch_home') { foldersFetchHome(); return; }
	if (folders.remote_uuid) { return; }
	var command = data['command'];
	if (command == 'copy') {
		folders.clipboard = folders.selected;
		folders.command = 'copy';
	}
	else if (command == 'cut') {
		folders.clipboard = folders.selected;
		folders.command = 'cut';
	}
	else if (command == 'select_all') {
		$('.folders_file').addClass('selected');
		folderSelection();
	}
	else if (command == 'open') {
		if (folders.type == 'folder') {
			foldersOpener({ folder: folders.path });
		}
		else {
			foldersFileOpener();
		}
	}
	else if (command == 'open_with') {
		foldersOpenWith();
	}
	else if (command == 'paste') {
		foldersPaste();
	}
	else if (command == 'archive') {
		foldersArchive();
	}
	else {
		var jfolders = JSON.stringify(folders);
		$.ajax({
			url: '/manager/folders/context/command',
			type: 'GET',
			data: {
				command: command,
				folders: jfolders
			},
			success:function(response) {
				$('#dialog_boxes').append(response.dialog);
				appointment_chron();
			}
		});
	}
}

// The toolbar is as thick as its items need - even one row of icons is taller
// than the bar's own minimum - so a drawer asks where its bottom is before
// hanging from it.
function foldersDrawerTop() {
	return $('#folders_toolbar').outerHeight() + 5;
}

// Bring what is selected - or the folder being looked at - back to this
// machine. The paths are on the machine being browsed, and it is that machine
// which says where they belong; the queue panel shows the work as it goes.
function foldersFetchHome() {
	var items = folders.selected || [];
	if (!items.length) {
		var path = folders.path || folders.folder;
		if (path) { items = [ { path: path } ]; }
	}
	var remote_uuid = folders.remote_uuid || $('#folders').attr('remote_uuid') || '';
	$.each(items, function (i, item) {
		$.ajax({
			url: '/manager/folders/archive/fetch',
			type: 'POST',
			data: { path: item['path'], remote_uuid: remote_uuid }
		});
	});
	$('#folders_archive_queue').css({ 'top': foldersDrawerTop() }).show();
	foldersArchiveQueue();
}

function foldersCommandConfirm(uuid) {
	var box = $('.dialog_box[uuid="' + uuid + '"]');
	var command = box.attr('command');
	var inputs = {};
	box.find('input').each(function() {
		inputs[$(this).attr('name')] = $(this).val();
	});
	box.remove();
	if (!command) { return; }
	foldersCommandPOST({ command: command, inputs: inputs });
}

// What a command with nothing more to ask does: the clipboard going into the
// folder on screen, and the desktop's own opener for a file.
function foldersPaste() {
	foldersCommandPOST({ command: 'paste' });
	// the paste is on its way, so a second one does not queue it again
	folders.clipboard = [];
	folders.command = undefined;
}

function foldersOpenWith() {
	$.ajax({
		url: '/manager/folders/open_with',
		type: 'POST',
		data: { folders: JSON.stringify(folders) }
	});
}

// A command from a dialog's OK, or one that needs no dialog at all. The answer
// is a dialog when there is something to say - a job's progress, or why the
// command would not go - and the folder is read again when it went.
function foldersCommandPOST(data) {
	$.ajax({
		url: '/manager/folders/context/command',
		type: 'POST',
		data: {
			command: data['command'],
			inputs: JSON.stringify(data['inputs'] || {}),
			folders: JSON.stringify(folders)
		},
		success: function(response) {
			if (response && response['dialog']) {
				$('#dialog_boxes').append(response['dialog']);
				appointment_chron();
				foldersJobWatcher();
			}
			if (response && response['status'] == 'ok') {
				foldersRefresh();
			}
		}
	});
}

// Read the folder being looked at again, in the window it is already in.
function foldersRefresh() {
	foldersOpener({ folder: folders['folder'] });
}

// A job's progress lives in the dialog box that started it: the box carries
// the job's id and asks after it once a second until the job is finished or
// failed, when the box keeps the last word and the folder is read again. The
// asking stops when no box is watching anything.
var folders_job_interval;
function foldersJobWatcher() {
	if (folders_job_interval) { return; }
	folders_job_interval = setInterval(function() {
		var boxes = $('.dialog_box[job]');
		if (!boxes.length) {
			clearInterval(folders_job_interval);
			folders_job_interval = undefined;
			return;
		}
		boxes.each(function() {
			var box = $(this);
			$.ajax({
				url: '/manager/folders/job',
				type: 'GET',
				data: { id: box.attr('job') },
				success: function(job) {
					if (!job || job['status'] != 'ok') {
						box.removeAttr('job').find('.job_progress').text('that job is gone');
						return;
					}
					var word = job['progress'] || job['state'];
					if (job['errors'] && job['errors'].length) { word = word + '\n' + job['errors'].join('\n'); }
					box.find('.job_progress').text(word);
					if (job['state'] == 'finished' || job['state'] == 'failed') {
						box.removeAttr('job');
						box.find('.job_stop').remove();
						foldersRefresh();
					}
				}
			});
		});
	}, 1000);
}

$(document).on('click', '.job_stop', function() {
	var button = $(this);
	button.closest('.dialog_box').find('.job_progress').text('stopping...');
	$.ajax({
		url: '/manager/folders/job/cancel',
		type: 'POST',
		data: { id: button.attr('job') }
	});
});

// Put the selection (or the folder being looked at) on the archive queue. The
// machine decides which location each item belongs to and where it goes; what
// comes back is how many were queued and why anything was not.
function foldersArchive() {
	$('body').css({ 'cursor': 'progress' });
	$.ajax({
		url: '/manager/folders/archive',
		type: 'POST',
		data: { folders: JSON.stringify(folders) },
		success: function (response) {
			$('body').css({ 'cursor': 'auto' });
			if (response && response.dialog) {
				$('#dialog_boxes').append(response.dialog);
			}
			if ($('#folders_archive_queue').is(':visible')) { foldersArchiveQueue(); }
		},
		error: function () {
			$('body').css({ 'cursor': 'auto' });
		}
	});
}

var folders_archive_interval;
var folders_archive_locations = [];
function foldersArchiveQueue() {
	$.ajax({
		url: '/manager/folders/archive',
		type: 'GET',
		success: function (response) {
			var box = $('#folders_archive_queue').empty();
			folders_archive_locations = (response && response['locations']) || [];
			if (folders_archive_locations.length) {
				var pick = $('<select>').appendTo(box);
				$.each(folders_archive_locations, function (i, l) {
					$('<option>').attr('value', l['location']).text(l['location'] + (l['remote_hostname'] ? ' on ' + l['remote_hostname'] : '')).appendTo(pick);
				});
				$('<button>').addClass('hover').text('rescan').css({ 'float': 'right' }).on('click', function () {
					foldersArchiveRescan(pick.val());
				}).appendTo(box);
			}
			var jobs = (response && response['jobs']) || [];
			if (!jobs.length) {
				$('<i>').text('Nothing is queued for the archive.').appendTo(box);
				return;
			}
			$.each(jobs, function (i, job) {
				var item = job['item'] || {};
				var name = (item['relative'] && item['relative'].length) ? item['relative'] : (item['path'] || '');
				var line = $('<div>').css({ 'border-bottom': 'solid 1px', 'padding': '3px', 'overflow-wrap': 'break-word' });
				var buttons = $('<span>').css({ 'float': 'right' });
				if (job['state'] == 'failed' || job['state'] == 'finished') {
					$('<button>').addClass('hover').text('retry').on('click', function () { foldersArchiveJob('retry', job['id']); }).appendTo(buttons);
				}
				else {
					$('<button>').addClass('hover').text('stop').on('click', function () { foldersArchiveJob('cancel', job['id']); }).appendTo(buttons);
				}
				buttons.appendTo(line);
				$('<b>').text(job['state']).appendTo(line);
				if (job['task'] == 'archive_manifest_rescan') {
					$('<span>').text(' reading ' + (item['location'] || '?') + ' again').appendTo(line);
				}
				else {
					$('<span>').text(' ' + name + '  ->  ' + (item['location'] || '?') + ' on ' + (item['remote_hostname'] || '?')).appendTo(line);
				}
				if (job['errors'] && job['errors'].length) {
					$('<div>').css({ 'font-size': '13px' }).text(job['errors'].join('; ')).appendTo(line);
				}
				else if (job['progress']) {
					$('<div>').css({ 'font-size': '13px' }).text(job['progress']).appendTo(line);
				}
				else if (job['sent'] || job['skipped']) {
					$('<div>').css({ 'font-size': '13px' }).text((job['sent'] || 0) + ' sent, ' + (job['skipped'] || 0) + ' already there').appendTo(line);
				}
				box.append(line);
			});
		}
	});
}

function foldersArchiveJob(action, id) {
	$.ajax({
		url: '/manager/folders/archive/' + action,
		type: 'POST',
		data: { id: id },
		success: function () { foldersArchiveQueue(); }
	});
}

// Ask the machine holding a location's archive to read that location again.
// The work happens there, where the drive is, not here.
function foldersArchiveRescan(location) {
	var remote_uuid = '';
	$.each(folders_archive_locations, function (i, l) {
		if (l['location'] == location) { remote_uuid = l['remote_uuid']; }
	});
	$.ajax({
		url: '/manager/folders/archive/manifest/rescan',
		type: 'POST',
		data: { location: location, remote_uuid: remote_uuid },
		success: function () { foldersArchiveQueue(); }
	});
}

$(document).on('click', '#folders_bookmarks_toggle', function () {
	var box = $('#folders_bookmarks');
	if (box.is(':visible')) {
		box.hide();
	}
	else {
		box.css({ 'top': foldersDrawerTop() }).show();
	}
});

// A bookmark is navigation only, so it works the same on a remote machine:
// the path means something there, and the machine being browsed stays put.
$(document).on('click', '.folders_bookmark', function () {
	var path = $(this).attr('path');
	$('#folders_bookmarks').hide();
	foldersOpener({ folder: path });
});

$(document).on('click', '#folders_archive_toggle', function () {
	var box = $('#folders_archive_queue');
	if (box.is(':visible')) {
		box.hide();
		clearInterval(folders_archive_interval);
	}
	else {
		box.css({ 'top': foldersDrawerTop() }).show();
		foldersArchiveQueue();
		folders_archive_interval = setInterval(foldersArchiveQueue, 3000);
	}
});
