function foldersDrawerTop() {
	return $('#folders_toolbar').outerHeight() + 5;
}

// Bring what is selected - or the folder being looked at - back to this
// machine. The paths are on the machine being browsed, and it is that machine
// which says where they belong; the queue panel shows the work as it goes.
function foldersFetchHome(state) {
	var st = state || folders;
	var items = st.selected || [];
	if (!items.length) {
		var path = st.path || st.folder;
		if (path) { items = [ { path: path } ]; }
	}
	var remote_uuid = st.remote_uuid || $('#folders').attr('remote_uuid') || '';
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
	// the app picker saves a list of names, not a file command
	if (command == 'pin_app') {
		var pinned = [];
		box.find('.desk_pin_check:checked').each(function () { pinned.push($(this).val()); });
		box.remove();
		if (typeof deskPinsSaveList == 'function') { deskPinsSaveList(pinned); }
		return;
	}
	// CloudSync picks its devices with checkboxes, then starts its own job
	if (command == 'cloud_sync') {
		var cloud_folder = box.attr('folder') || '';
		var cloud_devices = [];
		box.find('.folders_cloud_device:checked').each(function () { cloud_devices.push($(this).val()); });
		box.remove();
		foldersCloudStart(cloud_folder, cloud_devices);
		return;
	}
	var surface = box.attr('state_surface') || 'folders';
	var st = (surface == 'desk') ? desk : folders;
	var inputs = {};
	box.find('input').each(function() {
		inputs[$(this).attr('name')] = $(this).val();
	});
	box.remove();
	if (!command) { return; }
	foldersCommandPOST({ command: command, inputs: inputs }, st);
}

// Choose (or reset) the folder the desk shows. The machine saves it; a visible
// desk is read again at once.
function foldersDeskFolder(folder) {
	$.ajax({
		url: '/manager/folders/desk/folder',
		type: 'POST',
		data: { folder: folder || '' },
		success: function(response) {
			if (response && response['ok'] && typeof deskRefreshIfVisible == 'function') {
				deskRefreshIfVisible();
			}
		}
	});
}

// The properties card's two buttons: put the path on the clipboard, or open its
// folder in the browser.
$(document).on('click', '.folders_copy_path', function () {
	var button = $(this);
	var path = button.attr('path') || '';
	var done = function () {
		button.text(jawnosT('Copied'));
		setTimeout(function () { button.text(jawnosT('Copy path')); }, 1200);
	};
	if (navigator.clipboard && navigator.clipboard.writeText) {
		navigator.clipboard.writeText(path).then(done, done);
	}
	else {
		var field = $('<textarea>').val(path).css({ position: 'fixed', left: '-9999px' }).appendTo('body');
		field[0].select();
		try { document.execCommand('copy'); } catch (e) { /* older engines */ }
		field.remove();
		done();
	}
});
$(document).on('click', '.folders_open_parent', function () {
	var path = $(this).attr('path');
	if (path) { foldersOpener({ folder: path, remote_uuid: ($(this).attr('remote') || '') }); }
});

// What a command with nothing more to ask does: the clipboard going into the
// folder on screen, and the desktop's own opener for a file.
function foldersPaste(state) {
	var st = state || folders;
	var surface = (st === desk) ? 'desk' : 'folders';
	foldersCommandPOST({ command: 'paste' }, st);
	// the paste is on its way, so a second one does not queue it again
	st.clipboard = [];
	st.command = undefined;
	foldersApplyCut(surface);
}

function foldersOpenWith(state) {
	$.ajax({
		url: '/manager/folders/open_with',
		type: 'POST',
		data: { folders: JSON.stringify(state || folders) }
	});
}

// A command from a dialog's OK, or one that needs no dialog at all. The answer
// is a dialog when there is something to say - a job's progress, or why the
// command would not go - and the folder is read again when it went.
function foldersCommandPOST(data, state) {
	var st = state || folders;
	var surface = (st === desk) ? 'desk' : 'folders';
	return $.ajax({
		url: '/manager/folders/context/command',
		type: 'POST',
		data: {
			command: data['command'],
			inputs: JSON.stringify(data['inputs'] || {}),
			folders: JSON.stringify(st)
		},
		success: function(response) {
			if (response && response['dialog']) {
				var box = $(response['dialog']).attr('state_surface', surface);
				$('#dialog_boxes').append(box);
				appointment_chron();
				foldersJobWatcher();
			}
			if (response && response['status'] == 'ok') {
				foldersRefreshAll();
			}
		}
	});
}

// Read every surface again: the window (when it is open) and the desk (when it
// is the chosen background). A job's own dialog calls this when it finishes.
function foldersRefreshAll() {
	if (folders && folders.place == 'cloud' && $('#folders').length) {
		foldersCloudList(foldersRoot());
		return;
	}
	if ($('#folders').length) {
		foldersOpener({ folder: $('#folders').attr('folder') || folders.folder });
	}
	if (typeof deskRefreshIfVisible == 'function') { deskRefreshIfVisible(); }
}
function foldersRefresh() { foldersRefreshAll(); }

// A job's progress lives in the dialog box that started it: the box carries
// the job's id and asks after it once a second until the job is finished or
// failed, when the box keeps the last word and the folder is read again. The
// asking stops when no box is watching anything.
var folders_job_interval;

function foldersArchiveT(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

// One bar per line, driven by the byte fractions the job note carries. The
// width is the overall job (or the single file) percentage, never a guess.
function foldersArchiveBar(archive) {
	var wrap = $('<div>').addClass('folders_job_bar');
	var track = $('<div>').addClass('folders_job_bar_track').appendTo(wrap);
	var pct = Math.max(0, Math.min(100, (archive && archive['percent']) || 0));
	$('<span>').addClass('folders_job_bar_fill').css({ 'width': pct + '%' }).appendTo(track);
	return wrap;
}

function foldersArchiveWords(archive) {
	if (!archive) { return ''; }
	var state = archive['state'] || 'queued';
	var words = {
		queued: 'Queued', copying: 'Copying', verifying: 'Verifying',
		done: 'Done', failed: 'Failed', cancelled: 'Cancelled'
	};
	var word = foldersArchiveT(words[state] || state);
	if (state == 'copying' || state == 'verifying' || state == 'queued') {
		word += ' ' + (archive['percent'] || 0) + '%';
		if (archive['file']) { word += ' - ' + archive['file']; }
		if (archive['file_bytes_total']) {
			word += ' (' + (archive['file_percent'] || 0) + '% of this file)';
		}
		if ((archive['files'] || 0) > 1) {
			word += ' - ' + (archive['index'] || 0) + ' of ' + archive['files'];
		}
	}
	if (archive['resumable']) { word += ' - ' + foldersArchiveT('resumes where it stopped'); }
	if (archive['delete_source']) { word += ' - ' + foldersArchiveT('removes the original after verifying'); }
	return word;
}

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
					if (job['archive']) { word = foldersArchiveWords(job['archive']); }
					if (job['errors'] && job['errors'].length) { word = word + '\n' + job['errors'].join('\n'); }
					var target = box.find('.job_progress .job_line');
					if (target.length) { target.text(word); }
					else { box.find('.job_progress').text(word); }
					var bar = box.find('.job_progress .job_bar');
					if (bar.length) {
						if (job['archive']) {
							bar.show().find('span').css({ 'width': Math.max(0, Math.min(100, job['archive']['percent'] || 0)) + '%' });
						}
						else { bar.hide(); }
					}
					if (job['state'] == 'finished' || job['state'] == 'failed') {
						box.removeAttr('job');
						box.find('.job_stop').remove();
						foldersRefreshAll();
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

// ---- archive ---------------------------------------------------------------
// Put the selection (or the folder being looked at) on the archive queue. The
// machine decides which location each item belongs to and where it goes; what
// comes back is how many were queued and why anything was not. delete_after is
// the explicit per-job choice to remove the original, never the default.
function foldersArchive(state, options) {
	var st = state || folders;
	var payload = st;
	if (options && options['delete_after']) {
		payload = $.extend(true, {}, st);
		payload['delete_after'] = 1;
	}
	$('body').css({ 'cursor': 'var(--jawnos-cursor-progress, progress)' });
	$.ajax({
		url: '/manager/folders/archive',
		type: 'POST',
		data: { folders: JSON.stringify(payload) },
		success: function (response) {
			$('body').css({ 'cursor': 'var(--jawnos-cursor-default, auto)' });
			if (response && response.dialog) {
				$('#dialog_boxes').append(response.dialog);
				foldersJobWatcher();
			}
			if ($('#folders_archive_queue').is(':visible')) { foldersArchiveQueue(); }
		},
		error: function () {
			$('body').css({ 'cursor': 'var(--jawnos-cursor-default, auto)' });
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
				$('<i>').text(foldersArchiveT('Nothing is queued to sync.')).appendTo(box);
				return;
			}
			// several items queue as several jobs; one line still says how the
			// whole archive run is going, summed from the same byte counts
			var all_done = 0, all_total = 0, all_count = 0;
			$.each(jobs, function (i, job) {
				if (job['archive'] && job['archive']['bytes_total']) {
					all_done += job['archive']['bytes_done'] || 0;
					all_total += job['archive']['bytes_total'];
					all_count++;
				}
			});
			if (all_count > 1 && all_total > 0) {
				var all_pct = Math.floor((all_done / all_total) * 100);
				var summary = $('<div>').css({ 'font-weight': 'bold', 'padding': '3px' });
				$('<span>').text(foldersArchiveT('All sync jobs') + ': ' + all_pct + '%').appendTo(summary);
				summary.append(foldersArchiveBar({ percent: all_pct }));
				box.append(summary);
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
				var job_state = (job['state'] == 'inactive') ? 'queued' : (job['state'] == 'active' ? 'copying' : job['state']);
				$('<b>').text(foldersArchiveT(job_state)).appendTo(line);
				if (job['task'] == 'archive_manifest_rescan') {
					$('<span>').text(' reading ' + (item['location'] || '?') + ' again').appendTo(line);
				}
				else if (job['task'] == 'cloud_sync') {
					var hosts = [];
					$.each(item['devices'] || [], function (n, d) { hosts.push(d['hostname'] || d['uuid']); });
					$('<span>').text(' ' + name + '  ->  ' + (hosts.join(', ') || foldersArchiveT('the chosen devices'))).appendTo(line);
				}
				else {
					$('<span>').text(' ' + name + '  ->  ' + (item['location'] || '?') + ' on ' + (item['remote_hostname'] || '?')).appendTo(line);
				}
				if (job['errors'] && job['errors'].length) {
					$('<div>').css({ 'font-size': '13px' }).text(job['errors'].join('; ')).appendTo(line);
				}
				else if (job['archive']) {
					line.append(foldersArchiveBar(job['archive']));
					$('<div>').css({ 'font-size': '13px' }).text(foldersArchiveWords(job['archive'])).appendTo(line);
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

// ---- cloud sync ------------------------------------------------------------
// Ask the machine which devices have room, then show one row per device. The
// dialog's OK starts the job; from then on the same watcher and the same queue
// drawer that show an archive transfer show this one.
function foldersCloudCheck(state) {
	var st = state || folders;
	var path = st.path || st.folder || '';
	$('body').css({ 'cursor': 'var(--jawnos-cursor-progress, progress)' });
	$.ajax({
		url: '/manager/folders/cloud',
		type: 'POST',
		data: { folder: path, folders: JSON.stringify(st) },
		success: function (response) {
			$('body').css({ 'cursor': 'var(--jawnos-cursor-default, auto)' });
			if (response && response.dialog) {
				$('#dialog_boxes').append($(response.dialog).attr('state_surface', (st === desk) ? 'desk' : 'folders'));
				appointment_chron();
			}
		},
		error: function () {
			$('body').css({ 'cursor': 'var(--jawnos-cursor-default, auto)' });
		}
	});
}

function foldersCloudStart(folder, devices) {
	$('body').css({ 'cursor': 'var(--jawnos-cursor-progress, progress)' });
	$.ajax({
		url: '/manager/folders/cloud/start',
		type: 'POST',
		data: { folder: folder || '', devices: JSON.stringify(devices || []) },
		success: function (response) {
			$('body').css({ 'cursor': 'var(--jawnos-cursor-default, auto)' });
			if (response && response.dialog) {
				$('#dialog_boxes').append($(response.dialog).attr('state_surface', 'folders'));
				appointment_chron();
				foldersJobWatcher();
			}
		},
		error: function () {
			$('body').css({ 'cursor': 'var(--jawnos-cursor-default, auto)' });
		}
	});
}

// The Places column's CloudSync row: render this machine's watched folders as
// a place in the listing pane. It is not a folder, so it does not join history;
// the breadcrumb's Home and the folder the person came from are the way back.
function foldersCloudList(root) {
	root = (root && root.length) ? root : foldersRoot();
	if (!root.length) { return; }
	var window_id = root.attr('data-folders-id') || (folders && folders.window_id) || '';
	var tab_id = root.attr('data-tab-id') || (folders && folders.tab_id) || '';
	var folder = (folders && folders.folder) || root.attr('folder') || '';
	var remote_uuid = (folders && folders.remote_uuid) || root.attr('remote_uuid') || '';
	$.ajax({
		url: '/manager/folders/cloud',
		type: 'GET',
		data: {
			window_id: window_id,
			tab_id: tab_id,
			folder: folder,
			remote_uuid: remote_uuid,
			timestamp: Date.now()
		},
		success: function (response) {
			if (!response || !response.html) { return; }
			windowMaker(response.html);
			window_id = response.window_id || window_id;
			tab_id = response.tab_id || tab_id;
			var fresh = foldersRootFor(window_id);
			if (!fresh.length) { return; }
			var inst = foldersInstanceFor(fresh);
			inst.root = fresh;
			var tab = null;
			$.each(inst.tabs, function (i, t) { if (t.id == tab_id) { tab = t; } });
			if (!tab) { tab = inst.tabs[inst.active]; }
			if (tab) {
				tab.place = 'cloud';
				tab.display_name = (response.place && response.place.name) || jawnosT('CloudSync');
			}
			foldersActivate(fresh);
			foldersApplyView(fresh);
			foldersObserveRoot(fresh);
			foldersSidebarApply(fresh);
			var active = folders_instances[window_id];
			foldersApplyWindowName(active);
			foldersTabsRender(active);
			fresh.find('.folders_contents').focus();
			if (typeof appointment_chron == 'function') { appointment_chron(); }
		}
	});
}

$(document).on('click', '.folders_cloud_open', function () {
	var root = $(this).closest('.folders_app');
	foldersActivate(root);
	foldersSidebarClose(root);
	foldersCloudList(root);
});

$(document).on('click', '.folders_cloud_stop', function () {
	var path = $(this).attr('path') || '';
	$.ajax({
		url: '/manager/folders/cloud/remove',
		type: 'POST',
		data: { folder: path },
		success: function () { foldersCloudList(); }
	});
});

$(document).on('click', '.folders_cloud_now', function () {
	var path = $(this).attr('path') || '';
	$.ajax({
		url: '/manager/folders/cloud/now',
		type: 'POST',
		data: { folder: path },
		success: function (response) {
			if (response && response.dialog) {
				$('#dialog_boxes').append(response.dialog);
				appointment_chron();
				foldersJobWatcher();
			}
			foldersCloudList();
		}
	});
});

// ---- sidebar ---------------------------------------------------------------
// One observer per window instance. The window's contents are replaced on every
// navigation, so the observer is re-made for the fresh root each time.
var folders_observers = {};
function foldersObserveRoot(root) {
	if (!root || !root.length || typeof ResizeObserver == 'undefined') { return; }
	var id = root.attr('data-folders-id');
	if (!id) { return; }
	var old = folders_observers[id];
	if (old) { try { old.disconnect(); } catch (e) { /* already gone */ } }
	var observer = new ResizeObserver(function () { foldersSidebarApply(root); });
	observer.observe(root[0]);
	folders_observers[id] = observer;
}
$(document).on('click', '#folders_sidebar_toggle', function () {
	foldersActivateFrom(this);
	var root = $(this).closest('.folders_app');
	// Toggle what is on screen, not the stored value: a fresh window has no
	// preference yet, and its Places column is closed, so the first press opens it.
	var visible = root.find('.folders_sidebar').is(':visible');
	try { localStorage.setItem('folders_sidebar', visible ? 'off' : 'on'); } catch (e) {}
	foldersSidebarApply(root);
});
$(document).on('click', '.folders_sidebar_place', function () {
	var root = $(this).closest('.folders_app');
	foldersActivate(root);
	var path = $(this).attr('path');
	var remote = $(this).attr('remote_uuid') || '';
	if (path) {
		var data = { folder: path };
		// an Archive place on a machine without the drive names the machine
		// that holds it; a local place leaves the current machine alone
		if (remote) { data.remote_uuid = remote; }
		foldersSidebarClose(root);
		foldersOpener(data);
	}
});

// ---- drawers ---------------------------------------------------------------
$(document).on('click', '#folders_bookmarks_toggle', function () {
	foldersActivateFrom(this);
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
	foldersActivateFrom(this);
	var path = $(this).attr('path');
	var remote = $(this).attr('remote_uuid') || '';
	$('#folders_bookmarks').hide();
	var data = { folder: path };
	if (remote) { data.remote_uuid = remote; }
	foldersOpener(data);
});

$(document).on('click', '#folders_archive_toggle', function () {
	foldersActivateFrom(this);
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

// ---- keyboard --------------------------------------------------------------
// The listing is one focusable control. A focused item is the selection, so the
// arrows walk it, Shift+arrows take a run, and the usual file-manager keys work.
function foldersGridColumns(container) {
	if (container.attr('data-view') == 'list') { return 1; }
	var first = container.find('.folders_file').first();
	if (!first.length) { return 1; }
	var item_width = first.outerWidth(true) || 110;
	return Math.max(1, Math.floor((container.innerWidth() || $(window).width()) / item_width));
}

function foldersMoveSelection(surface, delta, extend, jump) {
	var container = foldersContainer(surface);
	var st = foldersState(surface);
	var items = container.find('.folders_file');
	if (!items.length) { return; }
	var current = items.filter('.selected');
	var index = current.length ? items.index(current.last()) : -1;
	var next;
	if (jump == 'home') { next = 0; }
	else if (jump == 'end') { next = items.length - 1; }
	else if (index < 0) { next = (delta > 0) ? 0 : items.length - 1; }
	else { next = Math.min(items.length - 1, Math.max(0, index + delta)); }
	if (extend && st.anchor !== undefined && items.eq(st.anchor).length) {
		var from = Math.min(st.anchor, next);
		var to = Math.max(st.anchor, next);
		items.removeClass('selected');
		items.slice(from, to + 1).addClass('selected');
	}
	else {
		items.removeClass('selected');
		items.eq(next).addClass('selected');
		st.anchor = next;
	}
	var el = items.eq(next);
	foldersSelectionSync(surface, el);
	if (el.length) { el[0].scrollIntoView({ block: 'nearest' }); }
}

function foldersKey(e, surface) {
	var container = foldersContainer(surface);
	if (!container.length) { return; }
	if ($(e.target).is('input, textarea, select, [contenteditable="true"]')) { return; }
	var st = foldersState(surface);
	var items = container.find('.folders_file');
	var key = e.key || '';
	var ctrl = e.ctrlKey || e.metaKey;
	if (ctrl && (key == 'a' || key == 'A')) {
		e.preventDefault();
		items.not('.desk_place').addClass('selected');
		foldersSelectionSync(surface, items.not('.desk_place').last());
		return;
	}
	if (ctrl && (key == 'c' || key == 'C')) { e.preventDefault(); foldersCommand({ command: 'copy' }, st); return; }
	if (ctrl && (key == 'x' || key == 'X')) { e.preventDefault(); foldersCommand({ command: 'cut' }, st); return; }
	if (ctrl && (key == 'v' || key == 'V')) { e.preventDefault(); foldersCommand({ command: 'paste' }, st); return; }
	if (ctrl && (key == 'l' || key == 'L') && surface == 'folders') { e.preventDefault(); foldersPathEdit(true); return; }
	if (key == 'Escape') {
		e.preventDefault();
		if ($('#folders').hasClass('edit_path')) { foldersPathEdit(false); }
		else { foldersClearSelection(surface); }
		return;
	}
	if (key == 'Delete') {
		e.preventDefault();
		if (st.selected && st.selected.length) { foldersCommand({ command: e.shiftKey ? 'shred' : 'delete' }, st); }
		return;
	}
	if (key == 'F2') {
		e.preventDefault();
		if (st.selected && st.selected.length == 1) { foldersCommand({ command: 'rename' }, st); }
		return;
	}
	if (key == 'Enter') {
		e.preventDefault();
		var chosen = items.filter('.selected').last();
		if (chosen.length && chosen.hasClass('desk_app')) {
			if (typeof deskOpenApp == 'function') { deskOpenApp(chosen.attr('app')); }
			else if (typeof appWindowOpener == 'function') { appWindowOpener(chosen.attr('app'), Date.now(), { visible: 'yes' }); }
			return;
		}
		if (chosen.length && chosen.hasClass('desk_place')) {
			foldersOpener({ folder: chosen.attr('path'), remote_uuid: '' });
			return;
		}
		if (st.selected && st.selected.length == 1) {
			st.path = st.selected[0]['path'];
			st.type = st.selected[0]['type'];
			foldersCommand({ command: 'open' }, st);
		}
		return;
	}
	if (key == 'ArrowLeft' || key == 'ArrowRight' || key == 'ArrowUp' || key == 'ArrowDown') {
		e.preventDefault();
		// Alt+Left/Right is the file-manager way back and forward through the
		// folders already visited; plain arrows walk the listing
		if (surface == 'folders' && e.altKey && (key == 'ArrowLeft' || key == 'ArrowRight')) {
			foldersHistoryMove((key == 'ArrowLeft') ? -1 : 1);
			return;
		}
		var delta = 0;
		if (key == 'ArrowRight') { delta = 1; }
		else if (key == 'ArrowLeft') { delta = -1; }
		else {
			var cols = foldersGridColumns(container);
			delta = (key == 'ArrowDown') ? cols : -cols;
		}
		foldersMoveSelection(surface, delta, e.shiftKey);
		return;
	}
	if (key == 'Home' || key == 'End') {
		e.preventDefault();
		foldersMoveSelection(surface, 0, e.shiftKey, (key == 'Home') ? 'home' : 'end');
		return;
	}
	if (key.length == 1 && !ctrl && !e.altKey) {
		var now = Date.now();
		if (now - folders_typeahead_at > 900) { folders_typeahead = ''; }
		folders_typeahead += key.toLowerCase();
		folders_typeahead_at = now;
		var match = null;
		items.each(function () {
			if (match) { return; }
			if (($(this).attr('data-name') || '').toLowerCase().indexOf(folders_typeahead) == 0) { match = $(this); }
		});
		if (match) {
			e.preventDefault();
			items.removeClass('selected');
			match.addClass('selected');
			st.anchor = items.index(match);
			foldersSelectionSync(surface, match);
			match[0].scrollIntoView({ block: 'nearest' });
		}
	}
}
$(document).on('keydown', '#folders_contents', function(e) { foldersKey(e, 'folders'); });
$(document).on('keydown', '#desk_layer', function(e) { foldersKey(e, 'desk'); });
