

$(document).on('click', '.measures_toggle', function() {
	measuresOpener();
});

function measuresOpener() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/measures',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			var st = $('#measures').scrollTop();
			windowMaker(response.window);
			$('#measures').scrollTop(st);
		}
	});
}

$(document).on('click', '.measures_pv', function() {
	var mpv = $(this);
	var m = mpv.closest('.measure');
	var measure = m.attr('measure');
	var name = m.attr('name');
	var uuid = m.attr('uuid');
	$('.measures_pv').removeClass('active_background');
	$('.app_measure').removeClass('active_background').removeClass('measurement_candidate');
	if (mpv.attr('measurement_searching') == 'on') {
		mpv.attr('measurement_searching', 'off');
		mpv.removeClass('active_background');
	}
	else {
		mpv.attr('measurement_searching', 'on');
		mpv.addClass('active_background');
		$('.app_measure').each(function(i,v) { 
			$(v).addClass('active_background');
			$(v).addClass('measurement_candidate');
		});
	}
});

$(document).on('click', '.measurement_candidate', function() {
	var mc = $(this);
	var mc_measure = mc.attr('measure');
	var mc_app = mc.closest('.appointment').attr('app');

	var ms = $('.measures_pv[measurement_searching="on"]');
	var m = ms.closest('.measure');
	var ms_measure = m.attr('measure');
	var ms_name = m.attr('name');
	var ms_uuid = m.attr('uuid');
	var data = {
		mc_measure: mc_measure,
		mc_app: mc_app,
		ms_measure: ms_measure,
		ms_name: ms_name,
		ms_uuid: ms_uuid
	};
	$('.measures_pv[measurement_searching="on"]').attr('measurement_searching', 'off');
	$('.measures_pv').removeClass('active_background');
	$('.app_measure').removeClass('active_background').removeClass('measurement_candidate');
	console.log(data);

	$.ajax({
		url: '/manager/measures/assign',
		type: 'POST',
		data: data,
		success: function(response) {
			console.log(response);
			measuresOpener()
		}
	});
});

$(document).on('click', '.measure_edit_toggle', function() {
	var uuid = $(this).attr('uuid');
	var mec = $('.measure_editor_container[uuid="' + uuid + '"]');
	if (mec.is(':visible')) {
		mec.hide();
	} else {
		mec.show();
	}
});

$(document).on('click', '.global_measures_save', function() {
	var uuid = $(this).attr('uuid');
	var data = { uuid: uuid };
	var container = $('.measure_editor_container[uuid="' + uuid + '"]');
	console.log(container);
	container.find('.measures_input').each( function(i,v) {
		console.log('hello');
		var name = $(v).attr('name');
		var value = $(v).val();

		data[name] = value;
		console.log(name + ' ' + value);
	});
	var jmeasure = JSON.stringify(data);
	$.ajax({
		url: '/manager/measures/edit',
		type: 'POST',
		data: {
			measure: jmeasure,
			timestamp: timestamp
		},
		success: function(response) {
			measuresOpener();
		}
	});
});

$(document).on('click', '.global_measures_delete', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/measures/delete',
			type: 'POST',
			data: { uuid: uuid },
			success:function(response) {
				$('.measure[uuid="' + uuid + '"]').remove();
				$('.measure_editor_container[uuid="' + uuid + '"]').remove();
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