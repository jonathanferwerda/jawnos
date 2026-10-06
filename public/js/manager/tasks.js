
$(document).on('click', '.tasks', function() {
	var timestamp = Date.now();
	var parent = $(this).closest('.appointment');
	var app = parent.attr('app');
	var container = $('.appointment[app="' + app + '"]').find('.re_tasks');
	if (container.is(':visible')) {
		container.hide();
	}
	else {
		appointmentTasksGrabber(app,timestamp);
	}
});

$(document).on('change', '.task_input', function(e) {
	var appt = $(this).closest('.appointment');
	var container = appt.find('.re_tasks');
	container.find('.task_list').css({
		'pointer-events': 'none',
		'opacity': '0.5',
		'filter': 'grayscale(1)'
	});
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
			appointmentTaskReopener(container,response.html);
			ac.scrollTop(top);
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