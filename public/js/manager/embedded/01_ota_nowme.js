function embeddedNowMePush() {
	// One Now Me for whatever device the panel is showing - the same call the
	// button makes, so a setting change can be carried to the watch at once.
	// now_me itself picks the link (the watch's LAN, else the BLE bridge).
	var nm = $('.embedded_now_me').first();
	$.ajax({
		url: '/manager/embedded/now_me',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			edt: edt,
			ip: nm.attr('ip'),
			chip_id: $('#embedded_device_chip_id').val(),
			name: $('#embedded_device_name').val(),
			uuid: nm.attr('uuid')
		},
		success: function(response) {}
	});
}

$(document).on('click', '.embedded_now_me', function() {
	embeddedNowMePush();
});

$(document).on('click', '.embedded_wigi', function() {
	var ip = $(this).attr('ip');
	var timestamp = Date.now();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	$.ajax({
		url: '/manager/embedded/wigi',
		type: 'GET',
		data: { edt: edt, timestamp: timestamp, ip: ip, chip_id:chip_id },
		success: function(response) {

		}
	});
});

function nowMeSuccess(edt,chip_id) {
	var enm = $('.embedded_now_me');
	var preColour = enm.css('background-color');
	enm.css({'background-color': 'lightgreen'});
	setTimeout(function() {
		enm.css({'background-color': preColour});
	},5000);
}

$(document).on('click', '.embedded_device_query', function() {
	var edt = $(this).attr('edt');
	var chip_id = $(this).attr('chip_id');
	var timestamp = Date.now();
	var info = $('.embedded_device_info[chip_id="' + chip_id + '"]');
	if (info.is(':visible')) {
		info.hide();
	} else {
		$.ajax({
			url: '/manager/embedded/device_query',
			type: 'GET',
			data: { timestamp: timestamp, edt: edt, chip_id: chip_id },
			success: function(response) {
				console.log(response);
				info.html(response.html);
				info.show();
			}
		});
	}
});

$(document).on('click', '.delete_embedded_file', function() {
	var a = $(this);
	var file = $(this).attr('file');
	var edt = $(this).attr('edt');
	var chip_id = $(this).attr('chip_id');
	var timestamp = Date.now();
	var t_uuid = a.closest('tr').attr('t_uuid');
	if (a.attr('armed') == 'yes') {
		a.css({'background-color': bgcolor });
		a.attr('armed', 'no');		
		$.ajax({
			url: '/manager/embedded/files/delete',
			type: 'POST',
			data: { timestamp: timestamp, edt: edt, chip_id: chip_id, file: file },
			success: function(response) {
				$('[t_uuid="' + t_uuid + '"]').remove();
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

$(document).on('click', '#embedded_ota_uploader', function() {
	var a = $(this);
	var timestamp = Date.now();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	if (a.attr('armed') == 'yes') {
		a.css({'background-color': bgcolor });
		a.attr('armed', 'no');		
		$.ajax({
			url: '/manager/embedded/ota_uploader',
			type: 'POST',
			data: { timestamp: timestamp, edt: edt, chip_id: chip_id },
			success: function(response) {
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

// the esp32 boards: first press arms, second press opens the file picker, the
// .bin goes to the manager and the manager pushes it to the board's own /update
$(document).on('click', '#embedded_ota_uploader_wifi', function() {
	var a = $(this);
	if (a.attr('armed') == 'yes') {
		a.css({'background-color': bgcolor });
		a.attr('armed', 'no');
		$('#embedded_ota_file').val('').trigger('click');
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

$(document).on('change', '#embedded_ota_file', function() {
	var file = this.files[0];
	if (!file) {
		return;
	}
	var ip = $('#embedded_ota_uploader_wifi').attr('ip');
	var timestamp = Date.now();
	var data = new FormData();
	data.append('firmware', file);
	data.append('ip', ip);
	data.append('timestamp', timestamp);
	$('#embedded_ota_uploader_wait').show();
	$('#embedded_ota_uploader_fail, #embedded_ota_uploader_success').hide();
	$('#embedded_ota_uploader_percentage').text('0%');
	$.ajax({
		url: '/manager/embedded/ota_uploader_wifi',
		type: 'POST',
		data: data,
		processData: false,
		contentType: false,
		xhr: function() {
			var xhr = new window.XMLHttpRequest();
			xhr.upload.addEventListener('progress', function(e) {
				if (e.lengthComputable) {
					var percent = Math.round(e.loaded / e.total * 100);
					$('#embedded_ota_uploader_percentage').text(percent + '%');
				}
			}, false);
			return xhr;
		},
		success: function(response) {
			$('#embedded_ota_uploader_wait').hide();
			if (response['success'] == 1) {
				$('#embedded_ota_uploader_percentage').text('100%');
				$('#embedded_ota_uploader_success').show();
			}
			else {
				$('#embedded_ota_uploader_percentage').text('');
				$('#embedded_ota_uploader_fail').show();
			}
		},
		error: function() {
			$('#embedded_ota_uploader_wait').hide();
			$('#embedded_ota_uploader_percentage').text('');
			$('#embedded_ota_uploader_fail').show();
		}
	});
});

// the esp32 boards are plugged into the homebase machine: the USB button has the
// manager run the PlatformIO upload and this just polls the log for progress
$(document).on('click', '#embedded_usb_uploader', function() {
	var a = $(this);
	if (a.attr('armed') == 'yes') {
		a.css({'background-color': bgcolor });
		a.attr('armed', 'no');
		usb_flash();
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

function usb_flash() {
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var port = $('#embedded_usb_port').val() || '';
	$('#embedded_ota_uploader_wait').show();
	$('#embedded_ota_uploader_fail, #embedded_ota_uploader_success').hide();
	$('#embedded_ota_uploader_percentage').text('');
	$.ajax({
		url: '/manager/embedded/usb_upload',
		type: 'POST',
		data: { edt: edt, chip_id: chip_id, port: port, timestamp: Date.now() },
		success: function(response) {
			if (response['ports']) {
				var sel = $('#embedded_usb_port').empty();
				$.each(response['ports'], function(i, p) {
					sel.append($('<option>').attr('value', p['path']).text(p['label']));
				});
				sel.show();
			}
			if (response['started'] == 1) {
				$('#embedded_usb_port').hide();
				$('#embedded_ota_uploader_percentage').text(response['port']);
				usb_flash_poll(0);
			}
			else {
				$('#embedded_ota_uploader_wait').hide();
				$('#embedded_ota_uploader_fail').show();
				$('#embedded_ota_uploader_percentage').text(response['result'] || '');
			}
		},
		error: function() {
			$('#embedded_ota_uploader_wait').hide();
			$('#embedded_ota_uploader_fail').show();
		}
	});
}

function usb_flash_poll(count) {
	if (count > 300) {
		$('#embedded_ota_uploader_wait').hide();
		$('#embedded_ota_uploader_fail').show();
		return;
	}
	$.ajax({
		url: '/manager/embedded/usb_upload_status',
		type: 'GET',
		data: { timestamp: Date.now() },
		success: function(response) {
			if (response['percent']) {
				$('#embedded_ota_uploader_percentage').text(response['percent'] + '%');
			}
			if (response['running'] == 1) {
				setTimeout(function() { usb_flash_poll(count + 1); }, 1200);
			}
			else {
				$('#embedded_ota_uploader_wait').hide();
				if (response['success'] == 1) {
					$('#embedded_ota_uploader_percentage').text('100%');
					$('#embedded_ota_uploader_success').show();
				}
				else {
					$('#embedded_ota_uploader_percentage').text(response['tail'] || '');
					$('#embedded_ota_uploader_fail').show();
				}
			}
		}
	});
}
// the watch/deck toggle for spoken replies: one click flips it, the save route
// writes it into the device's operator door, and the device gets a fresh Now Me
$(document).on('click', '.audio_replies_toggle', function() {
	var t = $(this);
	var value = t.attr('status') == 'on' ? 'off' : 'on';
	$.ajax({
		url: '/manager/embedded/setting',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			setting: t.attr('setting'),
			value: value,
			edt: t.attr('edt'),
			chip_id: t.attr('chip_id')
		},
		success: function(response) {
			t.attr('status', value);
			t.text('Audio replies: ' + (value == 'on' ? 'On' : 'Off'));
			embeddedNowMePush();
		}
	});
});

$(document).on('click', '#tty_enabled', function() {
	var t = $(this);
	var enabled = t.attr('status');
	var timestamp = Date.now();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	$.ajax({
		url: '/manager/teletype/enable_tty',
		type: 'POST',
		data: { timestamp: timestamp, enabled: enabled, edt: edt, chip_id: chip_id },
		success: function(response) {
			t.attr('status', response['enabled']);
			if (response['enabled'] == 1) {
				t.text('Disable');
			}
			else {
				t.text('Enable');
			}
		}
	});
});

$(document).on('click', '.embedded_diagram_thumb', function() {
	var uuid = $(this).attr('uuid');
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';

	$.ajax({
		url: '/manager/watch/diagram',
		type: 'GET',
		data: { uuid: uuid, edt: edt, chip_id: chip_id },
		success: function(response) {
			$('#embedded_diagram').html(response.html).show();
			$('#embedded_diagrams_home, #embedded_diagrams_save, #embedded_diagrams_cancel').show();
			$('#embedded_diagrams').hide();
			edtDiagramsReset();
			$('.embedded_diagram_draggable').draggable({
				scroll: false,
				revert: true,
				helper: 'clone',
				start: function(p) {
				},
				stop: function(m,g) {
					var id = m.target.id;
					var uuid = $('#' + id).attr('uuid');
					var w = $('#embedded_diagram_canvas');
					var x = m.originalEvent.clientX;
					var y = m.originalEvent.clientY;
					if (m.originalEvent.targetTouches) {
						x = m.originalEvent.targetTouches[0].clientX;
						y = m.originalEvent.targetTouches[0].clientY;
					}
					x = numeral(x - w.offset().left).value();
					y = numeral(y - w.offset().top).value();
					var xp = x / w.width();
					var yp = y / w.height();
					var canvas = document.getElementById('embedded_diagram_canvas');
					var ctx = canvas.getContext('2d');
					xp = canvas.width * xp - 50;
					yp = canvas.height * yp - 50;
					edtDiagramsComponentPlacer({ 'uuid': uuid, x: xp, y: yp, height: 100, width: 100 });
				}
			});
		}
	});
});

function edtDiagramsComponentPlacer(data) {
	var canvas = document.getElementById('embedded_diagram_canvas');
	var ctx = canvas.getContext('2d');
	var uuid = data['uuid'];
	var xp = data['x'];
	var yp = data['y'];
	var width = data['width'] || 100;
	var height = data['height'] || 100;
	var component = $('.embedded_diagram_component[uuid="' + uuid + '"]');
	var id = component.attr('id');
	var image = $('#' + id).find('.window_icon').attr('src');
	var name = $('#' + id).find('.component_name').text();
	var type = $('#' + id).find('.component_type').text();

	ctx.font = "400 40px Arial";
	ctx.lineWidth = 10;
	ctx.strokeRect(xp, yp, width, height);
	var typeSize = ctx.measureText(type);
	ctx.fillText(type, (xp + (width / 2)) - (typeSize.width / 2), yp + 140);
	var nameSize = ctx.measureText(name);
	ctx.fillText(name, (xp + (width / 2)) - (nameSize.width / 2), yp - 20);
	var img = new Image;
	img.onload = function(){
		ctx.drawImage(img,xp,yp, width, height);
	};
	img.src = image;
	edt_diagrams.components.push({ 'uuid': uuid, x: xp, y: yp, height: height, width: width });
}

$(document).on('click', '#embedded_diagrams_home', function() {
	$('#embedded_diagram,#embedded_diagrams_home,#embedded_diagrams_save,#embedded_diagrams_cancel').hide();
	$('#embedded_diagrams').show();
});

$(document).on('click', '#embedded_diagrams_cancel', function() {
	edtDiagramsReset('reset');
});

function edtDiagramsReset(type) {
	var canvas = document.getElementById('embedded_diagram_canvas');
	var c = $('#embedded_diagram_canvas');
	var i = $('#embedded_diagram_image');

	var info = JSON.parse($('#embedded_diagram_info').text());
	if (type == 'reset') {
		info.components = [];
		edt_diagrams = { components: info.components || [], file: info };
	}
	canvas.width = info.info.width;
	canvas.height = info.info.height;
	c.width(i.width());
	var iv = document.getElementById('embedded_diagram_image');
	var image = new Image();
	image.onload=function(){
		canvas.getContext('2d').drawImage(image,0,0,canvas.width, canvas.height);
		$.each(info.components, function(i,v) {
			edtDiagramsComponentPlacer(v);
		});



	};
	image.src = iv.src;
	i.hide();
	c.show();
}

$(document).on('click', '#embedded_diagrams_save', function() {
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var jedt_diagrams = JSON.stringify(edt_diagrams);
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/watch/diagram',
		type: 'POST',
		data: {
			edt: edt,
			chip_id: chip_id,
			diagram: jedt_diagrams,
			timestamp: timestamp
		},
		success: function(response) {
		}
	});
});


















