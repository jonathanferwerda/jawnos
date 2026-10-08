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
			var m = mouse_position();
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
		foldersOpener({ folder: folders.path });
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
			}
		});
	}
}

function foldersCommandConfirm(data) {
	$('[uuid="' + uuid + '"]').remove();

}

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

$(document).on('click', '#folders_archive_toggle', function () {
	var box = $('#folders_archive_queue');
	if (box.is(':visible')) {
		box.hide();
		clearInterval(folders_archive_interval);
	}
	else {
		box.show();
		foldersArchiveQueue();
		folders_archive_interval = setInterval(foldersArchiveQueue, 3000);
	}
});
