
$(document).on('click', '.tasks', function() {
	var timestamp = Date.now();
	var parent = $(this).closest('.appointment');
	var app = parent.attr('app');
	var container = $('.appointment[app="' + app + '"]').find('.re_tasks');
	if (container.is(':visible')) {
		container.hide();
	}
	else {
		appActExclusive(app, 'tasks');
		appointmentTasksGrabber(app,timestamp);
	}
});

$(document).on('change', '.task_input', function(e) {
	var appt = $(this).closest('.appointment');
	var container = appt.find('.re_tasks');
	// the busy dim is a class, not four inline styles: the re-render replaces this
	// element, and the rebuilt markup has to come back carrying only the theme's
	// own surfaces (see .task_list_busy in manager.css)
	container.find('.task_list').addClass('task_list_busy');
	var pa = projectAccountGrabber($(this));
	var account = pa['account'];
	var project = pa['project'];
	var movement = pa['movement'];
	var item = $(this).closest('.task_item');
	var uuid = item.attr('uuid');
	var name = $(this).attr('name');
	var value = $(this).val();

	var ac = $(this).closest('.appointment_contents');
	var top = ac.scrollTop();
	var papp = appt.attr('app');
	var app = $(this).closest('.task_list').attr('app');
	if ($(this).is(':checkbox')) {
		if ($(this).prop('checked')) {
			value = 'on';
		}
		else {
			value = 'off';
		}
	}


	var colour = item.find('.task_colour').val();
	$.ajax({
		url: '/manager/tasks',
		type: 'POST',
		data: { timestamp: timestamp, app: app, papp: papp, name: name, value: value, uuid: uuid, colour: colour, project: project, account: account, movement: movement },
		success: function(response) {
			var reopen = function() {
				appointmentTaskReopener(container,response.html);
				ac.scrollTop(top);
			};
			// Under the Open filter a tick takes the row out of the list. Let it
			// leave the way a window does - the desk's own close farewell, at the
			// desk's own Window Effects level - and rebuild the list when it ends.
			// Any other filter keeps the row, so it is swapped in at once.
			if (taskLeavesOpenList(item, container, name, value)
				&& typeof jawnosWindowCloseEffect === 'function') {
				// the save has answered, so the row leaves at full colour
				container.find('.task_list').removeClass('task_list_busy');
				if (jawnosWindowCloseEffect(item[0], reopen)) { return; }
			}
			reopen();
		}
	});
});

$(document).on('change', '.task_admin_input', function() {
	var timestamp = Date.now();
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var appt = $(this).closest('.appointment');
	var item = $(this).closest('.task_item');
	var app = $(this).closest('.task_list').attr('app');
	settingSetter({ 'app': app, 'setting': 'tasks_' + setting, 'value': value });
	setTimeout(function() {
		appointmentTasksGrabber(app,timestamp);
	}, 400);
});

$(document).on('click', '.delete_task', function() {
	var a = $(this);
	var appt = a.closest('.appointment');
	var papp = appt.attr('app');
	var app = a.closest('.task_list').attr('app');
	var uuid = a.closest('.task_item').attr('uuid');
	var container = appt.find('.re_tasks');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/tasks/delete',
			type: 'POST',
			data: { app: app, uuid: uuid, papp: papp },
			success: function(response) {
				appointmentTaskReopener(container,response.html);
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

function appointmentTasksGrabber(app,timestamp) {
	var container = $('.appointment[app="' + app + '"]').find('.re_tasks');
	var ac = $('.appointment_contents[app="' + app + '"]');
	var top = ac.scrollTop();



	$.ajax({
		url: '/manager/tasks',
		type: 'GET',
		data: { timestamp: timestamp, app: app },
		success: function(response) {
			appointmentTaskReopener(container,response.html);
			container.show();
			appActSync(app);
			appointment_chron();
			ac.scrollTop(top);
		}
	});
}

function appointmentTaskReopener(container,html) {
	var open_tasks = [];
	var selector = selectorMaker($(':focus')[0]);
	$('.task_settings').each(function(i,v) {
		if ($(v).is(':visible')) {
			open_tasks.push($(v).attr('uuid'));
		}
	});
	container.html(html);
	$.each(open_tasks, function(i,v) {
		taskSettingsOpener(v);
	});
	$(selector).focus();
}

// Does this change take its row out of the list? Only a tick under the Open
// filter does: the server rebuild drops the completed task. A nested list has
// no Sort/Filter row of its own (and keeps its own setting), so only the list
// the filter belongs to answers here - otherwise a checked child would crumble
// and then reappear in the rebuilt markup. The window-close farewell is reused
// as is, so the desk's Window Effects level (and reduced motion) decides it.
function taskLeavesOpenList(item, container, name, value) {
	if (name !== 'completed' || value !== 'on') { return false; }
	var top = container.children('.task_list');
	var list = item.closest('.task_list');
	if (!top.length || !list.length || top[0] !== list[0]) { return false; }
	return (container.find('.task_admin_input[setting="filter"]').val() || '') === 'open';
}

function taskSettingsOpener(uuid) {
	var settings = $('.task_settings[uuid="' + uuid + '"]');
	if (settings.is(':visible') ) {
		settings.hide();
		settings.closest('.task_item').css({ 'height': '45px' });
	}
	else {
		settings.show();
		settings.closest('.task_item').css({ 'height': '280px' });
	}
}

$(document).on('click', '.task_settings_hider', function() {
	var uuid = $(this).attr('uuid');
	taskSettingsOpener(uuid);
});