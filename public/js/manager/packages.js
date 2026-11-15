// The Packages app: what software this machine runs and the few changes the
// house may make to it. The manager is whatever the server detected; a machine
// with none (a phone's prebuilt runtime) gets a read-only list and says so.
//
// The core bundle does not carry this file: it is the lazy chunk the window
// loads, and lazy.js replays the first start-menu click into packagesOpener().
var packagesBusy = false;

$(document).on('click', '#packages_toggle, .packages_toggle', function() {
	packagesOpener();
});

function packagesOpener(timestamp) {
	if (!timestamp) { timestamp = Date.now(); }
	$.ajax({
		url: '/manager/packages',
		type: 'GET',
		data: { timestamp: timestamp, user_agent: navigator.userAgent },
		success: function(response) {
			if (!response) { return; }
			windowMaker(response.window || response);
			packagesBind();
			packagesLoad();
		}
	});
}

function packagesBind() {
	var window_box = $('.wind[app="packages"]');
	if (!window_box.length || window_box.data('packages_bound')) { return; }
	window_box.data('packages_bound', 1);

	window_box.on('click', '#packages_refresh', function() { packagesLoad(); });
	window_box.on('change', '#packages_backend', function() { packagesLoad(); });
	window_box.on('click', '#packages_search_go', function() { packagesSearchGo(); });
	window_box.on('keydown', '#packages_search_term', function(event) {
		if (event.key === 'Enter') { packagesSearchGo(); }
	});
	window_box.on('click', '#packages_update', function() { packagesUpdate(); });
	window_box.on('click', '#packages_upgrade', function() { packagesUpgrade(); });
	window_box.on('click', '#packages_install_go', function() { packagesInstall(); });
	window_box.on('keydown', '#packages_install_name', function(event) {
		if (event.key === 'Enter') { packagesInstall(); }
	});
	window_box.on('click', '#packages_file_go', function() { packagesFile(); });
	window_box.on('click', '.packages_remove', function() {
		packagesRemove($(this).attr('data-name'));
	});
	window_box.on('click', '.packages_purge', function() {
		packagesPurge($(this).attr('data-name'));
	});
}

// The backend the person chose, or empty for the machine's own manager. The
// server sends the list; a machine with one manager never shows the selector.
function packagesBackend() {
	var select = $('#packages_backend');
	return select.length ? (select.val() || '') : '';
}

// A package change only runs in a window the desktop app opened. The desktop
// sets window.JawnDesktop at document start (desktop/jawnos_desktop/bridge.py,
// DESKTOP_MARKER_JS); a plain browser has no such marker. This is the same
// check the remote-window and app-login code already keys off, not a new one.
function packagesWriteAllowed() {
	if (window.JawnDesktop) { return true; }
	packagesNote(jawnosT('Package changes run only in the JawnOS desktop window. Open JawnOS to install, remove or purge software.'));
	return false;
}

function packagesNote(text) {
	$('#packages_status_line').text(text || '');
}

function packagesEscape(text) {
	return $('<div>').text(text == null ? '' : String(text)).html();
}

function packagesHumanSize(kilobytes) {
	if (kilobytes === null || kilobytes === undefined || kilobytes === '') {
		return '';
	}
	var bytes = Number(kilobytes) * 1024;
	if (!isFinite(bytes) || bytes <= 0) { return ''; }
	var units = ['B', 'KB', 'MB', 'GB', 'TB'];
	var index = 0;
	while (bytes >= 1024 && index < units.length - 1) { bytes = bytes / 1024; index++; }
	return (index ? bytes.toFixed(1) : bytes.toFixed(0)) + ' ' + units[index];
}

function packagesLoad() {
	packagesNote(jawnosT('Reading the installed and outdated lists...'));
	$.ajax({
		url: '/manager/packages/list',
		type: 'GET',
		data: { backend: packagesBackend() },
		dataType: 'json',
		success: function(response) {
			packagesRenderInstalled(response);
		},
		error: function() {
			$('#packages_installed').html('<div class="packages_empty">' + jawnosT('The installed list could not be read.') + '</div>');
		}
	});
	$.ajax({
		url: '/manager/packages/outdated',
		type: 'GET',
		data: { backend: packagesBackend() },
		dataType: 'json',
		success: function(response) {
			packagesRenderOutdated(response);
			packagesNote(jawnosT('Ready.'));
		},
		error: function() {
			$('#packages_outdated').html('<div class="packages_empty">' + jawnosT('The outdated list could not be read.') + '</div>');
		}
	});
}

function packagesRenderInstalled(response) {
	var rows = (response && response.packages) || [];
	var read_only = !!(response && response.read_only);
	var html = '';
	if (!rows.length) {
		html = '<div class="packages_empty">' + (read_only
			? jawnosT('This runtime names no binaries to list.')
			: jawnosT('No installed packages were reported.')) + '</div>';
	}
	else {
		for (var i = 0; i < rows.length; i++) {
			var row = rows[i];
			html += '<div class="packages_row">'
				+ '<span class="packages_row_name">' + packagesEscape(row.name) + '</span>'
				+ '<span class="packages_row_version">' + packagesEscape(row.version || '') + '</span>'
				+ '<span class="packages_row_size">' + packagesEscape(packagesHumanSize(row.size_kb)) + '</span>';
			if (!read_only) {
				html += '<button class="packages_remove" data-name="' + packagesEscape(row.name) + '" hint="' + jawnosT('Remove this package') + '">' + jawnosT('Remove') + '</button>'
					+ '<button class="packages_purge" data-name="' + packagesEscape(row.name) + '" hint="' + jawnosT('Purge this package, including its configuration') + '">' + jawnosT('Purge') + '</button>';
			}
			html += '</div>';
		}
	}
	if (response && response.capped) {
		html += '<div class="packages_more">' + jawnosT('The list is capped; only the first rows are shown.') + '</div>';
	}
	$('#packages_installed').html(html);
	$('#packages_installed_count').text(rows.length ? jawnosT('rows') + ': ' + rows.length : '');
}

function packagesRenderOutdated(response) {
	var rows = (response && response.packages) || [];
	var html = '';
	if (!rows.length) {
		html = '<div class="packages_empty">' + (response && response.read_only
			? jawnosT('This runtime has no package manager.')
			: jawnosT('Everything is up to date.')) + '</div>';
	}
	else {
		for (var i = 0; i < rows.length; i++) {
			var row = rows[i];
			html += '<div class="packages_row">'
				+ '<span class="packages_row_name">' + packagesEscape(row.name) + '</span>'
				+ '<span class="packages_row_version">' + packagesEscape(row.from || '') + ' &rarr; ' + packagesEscape(row.version || '') + '</span>'
				+ '</div>';
		}
	}
	$('#packages_outdated').html(html);
	$('#packages_outdated_count').text(rows.length ? jawnosT('rows') + ': ' + rows.length : '');
}

function packagesSearchGo() {
	var term = $.trim($('#packages_search_term').val() || '');
	if (!term) { return; }
	packagesNote(jawnosT('Searching...'));
	$.ajax({
		url: '/manager/packages/search',
		type: 'GET',
		data: { term: term, backend: packagesBackend() },
		dataType: 'json',
		success: function(response) {
			var rows = (response && response.packages) || [];
			var html = '';
			if (!rows.length) {
				html = '<div class="packages_empty">' + jawnosT('Nothing matched that search.') + '</div>';
			}
			else {
				for (var i = 0; i < rows.length; i++) {
					var row = rows[i];
					html += '<div class="packages_row">'
						+ '<span class="packages_row_name">' + packagesEscape(row.name) + '</span>'
						+ '<span class="packages_row_version">' + packagesEscape(row.version || '') + ' '
						+ packagesEscape(row.description || '') + '</span>'
						+ '<button class="packages_install_one" data-name="' + packagesEscape(row.name) + '">' + jawnosT('Install') + '</button>'
						+ '</div>';
				}
			}
			if (response && response.capped) {
				html += '<div class="packages_more">' + jawnosT('The list is capped; only the first rows are shown.') + '</div>';
			}
			$('#packages_search_results').html(html);
			$('#packages_search_section').show();
			$('.wind[app="packages"]').off('click', '.packages_install_one').on('click', '.packages_install_one', function() {
				packagesInstall($(this).attr('data-name'));
			});
			packagesNote(response && response.ok ? jawnosT('Ready.') : jawnosT('The search did not run.'));
		},
		error: function() {
			packagesNote(jawnosT('The search did not run.'));
		}
	});
}

// One write at a time: the server holds the lock too, but a second click while
// the first request is still out would only queue behind it.
function packagesPost(url, data, after) {
	if (!packagesWriteAllowed()) { return; }
	if (packagesBusy) {
		packagesNote(jawnosT('A package operation is already running.'));
		return;
	}
	packagesBusy = true;
	data = data || {};
	if (packagesBackend()) { data.backend = packagesBackend(); }
	$.ajax({
		url: url,
		type: 'POST',
		data: data,
		dataType: 'json',
		success: function(response) {
			packagesBusy = false;
			packagesAnswer(response);
			if (after) { after(response); }
		},
		error: function(xhr) {
			packagesBusy = false;
			var response = null;
			try { response = JSON.parse(xhr.responseText); } catch (ignore) {}
			packagesAnswer(response || { ok: 0, error: jawnosT('The request did not run.') });
		}
	});
}

function packagesAnswer(response) {
	if (!response) { return; }
	var text = response.ok ? (response.output || response.what || '') : (response.error || response.output || '');
	if (!text) {
		text = response.ok ? jawnosT('Done.') : jawnosT('The request did not run.');
	}
	packagesNote(String(text).split('\n').slice(-3).join(' '));
	if (response.note) { packagesNote(jawnosT(response.note)); }
	if (response.needs_root) {
		packagesNote(jawnosT('This needs root, and sudo -n was refused. No password is asked for here.'));
	}
	if (response.restart_needed) {
		$('#packages_restart').text(jawnosT('A restart is needed so the running system uses the new packages.')).show();
	}
	if (response.ok) { packagesLoad(); }
}

function packagesUpdate() {
	if (!packagesWriteAllowed()) { return; }
	packagesNote(jawnosT('Refreshing the package index...'));
	packagesPost('/manager/packages/update', { confirm: 1 });
}

function packagesUpgrade() {
	if (!packagesWriteAllowed()) { return; }
	jawnosConfirm(jawnosT('Upgrade every outdated package now?'), function() {
		packagesNote(jawnosT('Upgrading every outdated package...'));
		packagesPost('/manager/packages/upgrade', { confirm: 1 });
	});
}

function packagesInstall(name) {
	if (!packagesWriteAllowed()) { return; }
	if (!name) { name = $.trim($('#packages_install_name').val() || ''); }
	if (!name) { return; }
	jawnosConfirm(jawnosT('Install this package now?') + ' ' + name, function() {
		packagesNote(jawnosT('Installing...'));
		packagesPost('/manager/packages/install', { confirm: 1, name: name });
	});
}

function packagesRemove(name) {
	if (!packagesWriteAllowed()) { return; }
	if (!name) { return; }
	jawnosConfirm(jawnosT('Remove this package now?') + ' ' + name, function() {
		packagesNote(jawnosT('Removing...'));
		packagesPost('/manager/packages/remove', { confirm: 1, name: name });
	});
}

function packagesPurge(name) {
	if (!packagesWriteAllowed()) { return; }
	if (!name) { return; }
	jawnosConfirm(jawnosT('Purge this package and its configuration now?') + ' ' + name, function() {
		packagesNote(jawnosT('Purging...'));
		packagesPost('/manager/packages/purge', { confirm: 1, name: name });
	});
}

function packagesFile() {
	if (!packagesWriteAllowed()) { return; }
	var input = document.getElementById('packages_file');
	if (!input || !input.files || !input.files.length) {
		packagesNote(jawnosT('Choose a package file to install.'));
		return;
	}
	jawnosConfirm(jawnosT('Install this package file now?'), function() {
		packagesFileSend(input);
	});
}

function packagesFileSend(input) {
	if (!packagesWriteAllowed()) { return; }
	var form = new FormData();
	form.append('confirm', '1');
	if (packagesBackend()) { form.append('backend', packagesBackend()); }
	form.append('file', input.files[0]);
	if (packagesBusy) {
		packagesNote(jawnosT('A package operation is already running.'));
		return;
	}
	packagesBusy = true;
	packagesNote(jawnosT('Installing the file...'));
	$.ajax({
		url: '/manager/packages/file',
		type: 'POST',
		data: form,
		processData: false,
		contentType: false,
		dataType: 'json',
		success: function(response) {
			packagesBusy = false;
			input.value = '';
			packagesAnswer(response);
		},
		error: function(xhr) {
			packagesBusy = false;
			var response = null;
			try { response = JSON.parse(xhr.responseText); } catch (ignore) {}
			packagesAnswer(response || { ok: 0, error: jawnosT('The file install did not run.') });
		}
	});
}
