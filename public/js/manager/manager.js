var nfc = {
	scanning: false,
	writing: false,
	abort: new AbortController(),
	initialized: false
};
var assistant = {};
if ('NDEFReader' in window) {
	nfc['ndef'] = new NDEFReader();
	nfcInitializer();
}
else { nfc['ndef'] = undefined; }

$(document).on('click', '.president_restart_trigger', function() {
	$.ajax({
		url:'/manager/president/restart',
		type: 'POST',
		success: function(response) {
			if (response == 'restarting') {
				if ($(this).attr('restart') == 'yes') {
					setTimeout(function() {

						window.location.reload();
					},3000);
				}
			}
		}
	});
});


if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/service_worker.js')
      .catch(err => console.log('Registration failed:', err));
  });
}


$(document).on('change', '#time_machine',function() {
	var ts = $(this).val();
	localStorage.setItem('time_machine',ts);
});


var focused_input;
var startMenuTimeout;
$(document).on('click', '.time_jump', function() {
	var j = $(this);
	var appointment = j.closest('.appointment');
	var type = j.attr('type');
	var timestamp = j.attr('timestamp') || timestamp;
	var app = j.attr('app');
	var delorean = deloreanBringer();
	var filter = localStorage.getItem('filter');
	$.ajax({
		url: '/manager/time_jump',
		type: 'GET',
		data: { timestamp: timestamp, filter: filter, type: type, app: app, scope: delorean.scope },
		success: function(response) {
			if (response.new_timestamp) {
				$('#time_machine').val(response.date);
				localStorage.setItem('time_machine',response.date);
				j.attr('timestamp',response.new_timestamp);
				j.closest('.walkman_controls').find('.time_jump').attr('timestamp',response.new_timestamp);
				appointmentDetailsGrabber(j);
			}
			else {
				$('.time_jump').attr('timestamp',response.old_timestamp);
			}
		}
	});

});

$(document).ready(function() {
	pseudonymFreeSpaceFinder();
	windowRetriever();
	nfcListener();
	if ($('#search_engines')) {

	}
	focused_input = $('#search');
	initializer();
	calculator();
	boxOfficeMaker();
	assistantInitializer();
});

$(document).on('click', '#assistant_close', function() {
	$('#assistant_view').hide();
});

async function assistantInitializer() {
	$('#assistant_view').draggable({
		revert: "false",
		zIndex: 999999,
		handle: '#assistant_anchor',
		cancel: '',
		start: function(p,ui) {
			console.log('started dragging a assistant');
		},
		drag: function(p,ui) {
			console.log('dragging a file/folder');
		  ui.position.left = p.pageX - 30;
		  ui.position.top = p.pageY - 30;
		},
		stop: function(p,ui) {
		}
	});


	$('#assistant').draggable({
		appendTo: "body",
		helper: "clone",
		revert: "invalid",
		zIndex: 999999,
		cursorAt: { top: 30, left: 30 },
		cancel: '',
		start: function(p,ui) {
			console.log('started dragging a assistant');
		//	$(this).css('opacity', '0');
		},
		drag: function(p,ui) {
			console.log('dragging a file/folder');
		  ui.position.left = p.pageX - 30;
		  ui.position.top = p.pageY - 30;
		},
		stop: function(p,ui) {
			$(this).css('opacity', '1');
			var m = mouse_position();
			var av = $('#assistant_view');
			var show_assistant = 0;

			
      var dropX = p.clientX;
      var dropY = p.clientY;

      // 2. Detect the element beneath the mouse cursor
      var elementLandedOn = document.elementFromPoint(dropX, dropY);
      
      // 3. Convert to jQuery object to interact with it easily
      var $target = $(elementLandedOn);
      console.log('Landed on:', elementLandedOn, 'ID:', $target.attr('id'), 'Class:', $target.attr('class'));
			var base64Data;
			// Set a maximum bound for width or height (Qwen handles 400px - 600px beautifully)
			var maxDimension = 600; 
			var image;
			var audio;
			if ($target.is('img')) {
				console.log('this is an image');
				var imgElement = $target[0]; // Get raw DOM element
				
				var origWidth = imgElement.naturalWidth || imgElement.width;
				var origHeight = imgElement.naturalHeight || imgElement.height;
				
				// Calculate new scaled dimensions
				var scale = Math.min(maxDimension / origWidth, maxDimension / origHeight, 1);
				var newWidth = origWidth * scale;
				var newHeight = origHeight * scale;

				var canvas = document.createElement('canvas');
				canvas.width = newWidth;
				canvas.height = newHeight;
				
				var ctx = canvas.getContext('2d');
				ctx.drawImage(imgElement, 0, 0, newWidth, newHeight);
				image = canvas.toDataURL('image/png');
				base64Data = image.split(',')[1];
				console.log('Downsized Image Base64 ready');

			} else if ($target.is('canvas')) {
				console.log('this is a canvas');
				var canvasElement = $target[0];
				
				var origWidth = canvasElement.width;
				var origHeight = canvasElement.height;
				
				var scale = Math.min(maxDimension / origWidth, maxDimension / origHeight, 1);
				var newWidth = origWidth * scale;
				var newHeight = origHeight * scale;

				// Create a temporary downsized canvas
				var tempCanvas = document.createElement('canvas');
				tempCanvas.width = newWidth;
				tempCanvas.height = newHeight;
				
				var ctx = tempCanvas.getContext('2d');
				ctx.drawImage(canvasElement, 0, 0, newWidth, newHeight);
				image = tempCanvas.toDataURL('image/png');
				base64Data = image.split(',')[1];
				console.log('Downsized Canvas Base64 ready');

			} else if ($target.is('video')) {
				console.log('this is a video snapshot');
				var videoElement = $target[0];
				
				var origWidth = videoElement.videoWidth || videoElement.width || 600;
				var origHeight = videoElement.videoHeight || videoElement.height || 400;
				
				var scale = Math.min(maxDimension / origWidth, maxDimension / origHeight, 1);
				var newWidth = origWidth * scale;
				var newHeight = origHeight * scale;
				
				var canvas = document.createElement('canvas');
				canvas.width = newWidth;
				canvas.height = newHeight;
				
				var ctx = canvas.getContext('2d');
				ctx.drawImage(videoElement, 0, 0, newWidth, newHeight);
				image = canvas.toDataURL('image/png');
				base64Data = image.split(',')[1];
				console.log('Downsized Video Snapshot Base64 ready');
			} else if ($target.is('audio')) {
				audio = $target.attr('src');
			}
			
			$('.assistant_content').html('<br><h1>Awaiting Response</h1>').show();
			if (image) {
				$('#assistant_image').attr('src', image).show();
			}
			else {
				$('#assistant_image').attr('src', undefined).hide();
			}
			if (audio) {
				$('#assistant_audio').attr('src',audio).show();
			}
			else {
				$('#assistant_audio').hide();
			}
			$.ajax({
				url: '/manager/assistant',
				type: 'POST',
				data: { image: base64Data, audio: audio },
				success:function(response) {
					$('.assistant_content').attr('uuid', response.uuid);




					av.show();
					
					av.css({ 'left': m.x - ( av.width() / 2), 'top': m.y, 'position':'fixed' });
					if ((numeral(av.css('left')).value() + numeral(av.width()).value()) > numeral($(window).width()).value()) {
						av.css({ 'right': (($(window).width() - m.x) +  ( av.width() / 2)), 'left': '' });
					}
					if (numeral(av.css('left')).value() < 3) {
						av.css({ 'left': '3px' });
					}
					if ((numeral(av.css('top')).value() + numeral(av.height()).value()) > numeral($(window).height()).value()) {
						av.css({ 'bottom': (($(window).height() - m.y)), 'top': '' });
					}

				}
			});

		}
	});
	







}

$(document).on('click dblclick mouseenter mouseleave keydown keyup change submit focus blur input', function(e) {
	nfcListener();
});

function nfcInitializer() {
	if (nfc['initialized'] == false) {
		nfc['initialized'] = true;
		nfc['ndef'].addEventListener("readingerror", () => {
		});
		nfc['abort'].signal.onabort = function() {
			nfc['scanning'] = false;
		};
		nfc['ndef'].addEventListener("reading", ({ message, serialNumber }) => {

			var md = [];
			$.each(message.records, function(i,record) {
				if (record.recordType === "text" || record.recordType === "url") {
					// 6. Decode the binary DataView payload into a string
					const textDecoder = new TextDecoder(record.encoding || "utf-8");
					const decodedString = textDecoder.decode(record.data);
					md.push({'text': decodedString });
				}
        if (record.mediaType === "application/json") {
				  const decoder = new TextDecoder();
					const json = JSON.parse(decoder.decode(record.data));
					md.push(json);
        }
			});

			var jmessage = JSON.stringify(md);
			var timestamp = Date.now();
			var lastWrite = nfc['lastWrite'];

			$.ajax({
				url: '/manager/nfc/read',
				type: 'POST',
				data: { message: jmessage, serial: serialNumber, last_write: lastWrite, timestamp: timestamp, benign: nfc['benign'] },
				success: function(response) {
					var jr = JSON.stringify(response);

					$('.nfc_read_status').text(response.status);
					setTimeout(function() {
						$('.nfc_read_status').text('');
					},10000);
				//	alert('reading tag ' + jr);
				}
			});
		});
	}
}

$(document).on('click', '.nfc_benign_reader', function() {
	var nb = $(this);
	var enabled = nb.attr('enabled');
	clearTimeout(nfc['benignTimeout']);
	if (enabled == 'on') {
		nfc['benign'] = 'off';
	}
	else {
		nfc['benign'] = 'on';
		nfc['benignTimeout'] = setTimeout(function() {
			nfc['benign'] = 'off';
			nb.attr('enabled', nfc['benign']);
		},10000);
	}
	nb.attr('enabled', nfc['benign']);
});

async function nfcListener() {
	if (nfc['ndef'] && nfc.scanning == false && nfc.writing == false) {

		try {
			nfc.scanning = true;
			nfc['abort'] = new AbortController();
			nfc['ndef'].scan({ signal: nfc['abort'].signal }).then(() => {
			}).catch(error => console.log(error));
		} catch {
			nfc.scanning = false;
		}
	}
}

async function nfcWriter(msg,a) {
	if (device == 'mobile') {
		if (nfc.scanning == true) {
			nfc.scanning = false;
			nfc.abort.abort();
			nfc['writing'] = true;
			setTimeout(function() {
				nfcWriter(msg,a);
			},1000);
		} else {
			try {
				a.addClass('active_background');
				nfc['writing'] = true;
				nfc.scanning = false;
			  const encoder = new TextEncoder();
				$.ajax({
					url: '/manager/nfc/write',
					type: 'POST',
					data: msg,
					success: function(response) {
						msg = encoder.encode(JSON.stringify(response.nfc));
						nfc['ndef'].write({
							records: [{
								recordType: 'mime',
								mediaType: 'application/json',
								data: msg
							}] }).then(() => {
							nfc['lastWrite'] = Date.now();
							nfc['writing'] = false;
							nfc['scanning'] = false;
							a.removeClass('active_background');
							nfcListener();
						});
					}
				});


			} catch (error) {
			}
		}
	}
}


$(document).on('click', 'input',function() {

	focused_input.removeClass('focused_input');
//	focused_input.css({'background-image': '' });
//	focused_input.trigger('change');
	focused_input = $(this);
//	focused_input.addClass('focused_input');

	if ($('#numberpad').is(':visible') || $('#keyboard').is(':visible')) {
		focused_input.blur();
	}
});
$(document).on('click', 'textarea',function() {
	focused_input = $(this);

	if ($('#numberpad').is(':visible') || $('#keyboard').is(':visible')) {
		focused_input.blur();
	}
});

$(document).on('click', '.app_act', function() {
	clearTimeout(searchTimeout);
});
var searchTimeout;

$(document).on('dblclick', 'input', function(i,e) {
	var s = $('#search');
	var search = s.val();
	if (search == '') {
		clipboardGetter(s);
	}
	else {
		clipboardSetter(search);
	}

	s.val('');
});

async function clipboardGetter(s) {
	$.ajax({
		url: '/manager/clipboard_getter',
		type: 'GET',
		success: function(response) {
			s.val(response);
		}
	});
}

$(document).on('click', '.clip', function() {
	clipboardSetter(clip);
});

function clipboardSetter(clip) {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/clipboard_setter',
		type: 'POST',
		data: { timestamp: timestamp, clipboard: clip },
		success: function(response) {

		}
	});
}

$(document).on('change', '.volume_control', function(e) {

	var control = $(this);
	var stream = control.attr('stream');
	var volume = control.val();
	var max_volume = control.attr('max');

	var total_width = control.width();
  var current_location = e.offsetX;

	control.val(volume);
	var timestamp = Date.now();
	var device = localStorage.getItem('volume_control_device');
	var data = { stream: stream, volume: volume, max: max_volume, device: device };
	$.ajax({
		url: '/manager/volume_control',
		type: 'GET',
		data: data,
		success: function(response) {
		 volumeChecker();
		}
	});

});

function volumeChecker() {
	var device = localStorage.getItem('volume_control_device');
	$.ajax({
		url: '/manager/volume_control',
		type: 'GET',
		data: { device: device },
		success: function(response) {
			var writer = '';
			$.each(response.volumes, function(i,v) {
				writer += '<b>' + v['stream'] + '</b><input type="range" style="width:60%;" class="volume_control" stream="' + v['stream'] + '" value="' + v['volume'] + '" max="' + v['max_volume'] + '"><br>';
			});
			$('#device_volume_control').html(writer);

			$.each(response.remote_machines, function(i,rm) {
				$('#device_volume_control').prepend('<span class="volume_control_device hover" device="' + rm.uuid + '"><b>' + rm.fqdn + '</b></span><br>');
			});

			$('#device_volume_control').prepend('<span class="volume_control_device hover" device="local"><b>Local</b></span><br>');
			$('.volume_control_device[device="' + device + '"]').addClass('selected');
		}
	});
}

$(document).on('click', '.volume_control_device', function() {
	$('.volume_control_device').removeClass('selected');
	$(this).addClass('selected');
	var device = $('.volume_control_device.selected').attr('device');
	localStorage.setItem('volume_control_device', device);
	volumeChecker();
});


$(document).on('click', '#cards_toggle', function() {
	$.ajax({
		url: '/manager/cards',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			windowMaker(response);
			setTimeout(function() {
				cardPicker();
			},1500);
		}
	});
});

var cardsInterval;
$(document).on('click', '.cards_mode', function() {
	var cc = $(this);
	var mode = cc.attr('mode');
	var status = cc.attr('status');
	$('.cards_mode').each(function(i,v) { $(v).attr('status', 'disabled'); });
	settingSetter({ 'app': 'cards', 'setting': 'mode', 'value': mode });
	setTimeout(function() {
		if (mode == 'cycle') {
			cardPicker();
			clearInterval(cardsInterval);
			cardsInterval = setInterval(function() {
				if ($('.cards_mode[mode=cycle]').attr('status') == 'enabled' && $('#deck_card').is(':visible')) {
					cardPicker('new');
				}
				else {
					clearInterval(cardsInterval);
				}
			}, 180000);
			cc.attr('status', 'enabled');
		}
		else {
			cardPicker();
			cc.attr('status', 'enabled');
		}
	},500);
});

$(document).on('click', '#deck_card', function() {
	cardPicker('new');
});

function cardPicker(new_card) {
	$('.card_description_icon').hide();
	$.ajax({
		url: '/manager/card_picker',
		type: 'GET',
		data: { timestamp: timestamp, new_card: new_card },
		success: function(response) {

			if (response.stream) {
				$('#deck_card').attr('src', response.stream);
				$('#deck_card').css({ 'height': '33%' });
				$('#deck_history').html($(response.html).find('#deck_history').html());
			}
			else {
				$('#deck_card').attr('src', '/images/cards/' + response.filename);
				$('#deck_card').css({ 'height': '80%' });
				$('#deck_history').html($(response.html).find('#deck_history').html());
			}
			
			$('#card_title').html(response.title).show();

			$('#card_description').text(response.description).hide();
			appointment_chron();
		}
	});
}

$(document).on('click', '.card.history', function() {
	var title = $(this).attr('title');
	var rn = $(this).attr('rn');
	var description = $('.card_history_description[rn="' + rn + '"]').html();
	$('#deck_card').attr('src', $(this).attr('src'));
	$('#card_title').html(title).show();
	$('#card_description').html(description).hide();
});

$(document).on('click', '#card_title,.card_description_icon', function() {
	$('#card_description').show();
	$('#card_title').hide();
});

$(document).on('click', '#card_description', function() {
	$('#card_title').show();
	$('#card_description').hide();
});

var key_index;
var original_key_position;
$(document).on('click', '#ticketmaker', function() {
	boxOffice();
});

$(document).on('change', '#box_office_view', function() {
	var view = $(this).val();
	settingSetter({ 'app': 'misc', 'setting': 'box_office_view', 'value': view });
	boxOffice();
});

function boxOffice() {
	var view = $('#box_office_view').val();
	$.ajax({
		url: '/manager/box_office',
		type: 'GET',
		data: { timestamp: timestamp, view: view },
		success: function(response) {
			boxOfficeMaker(response);
		}
	});
}

$(document).on('click', '.ticket_approve', function() {
	var timestamp = Date.now();
	var ticket = $(this).attr('ticket');
	$.ajax({
		url: '/manager/box_office/approve/',
		type: 'POST',
		data: { timestamp: timestamp, ticket: ticket },
		success: function(response) {

		},
		error: function(response) {

		}
	});
});

function boxOfficeMaker(response) {
	if (response) {
		windowMaker(response);
		$('#box_office').show();
		if (original_key_position == undefined) {
			original_key_position = {
				top: $('#ticket_sales').css('top'),
				left: $('#ticket_sales').css('left')
			};
		}
		$('#ticket_sales').show();
		$('#ticket_sales').draggable({
			start: function(p) {

				$('.unlock').show();
				key_index = $('#ticket_sales').css('z-index');

			},
			drag: function(p) {


			},
			stop: function(p) {

				$('.unlock').hide();

			}
		});
	}
}



$(document).on('click', '.box_office_close_button', function() { 
	$('#ticket_sales').hide();

	$('#ticket_sales').css(original_key_position);
});

function qrcode_generator(app) {
	var timestamp = Date.now();
	var nic = $('#ticket_network_device').val();
	var name = $('#ticket_name').val();
	var warranty = $('#ticket_warranty').val();
	var privilege = $('#ticket_privilege').val();
	var project = $('#ticket_project').val();
	var debriefer = JSON.stringify(localStorage);

	$.ajax({
		url: '/manager/qrcode_generator',
		type: 'GET',
		data: { timestamp: timestamp, nic: nic, debriefer:debriefer, name: name, warranty: warranty, privilege: privilege, app: app, project: project },
		success: function(response) {
			if (response) {
				ticket_list();
			}
		}
	});
}

function ticket_list() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/box_office',
		type: 'GET',
		data: { timestamp: timestamp, source: 'list' },
		success:function(response) {

			var tl = $(response).find('#ticket_list').html();

			$('#ticket_list').html(tl);
		}
	});
}

$(document).on('click', '.ticket', function() {
	var t = $(this);
	var width = t.width();
	if (width < 200) {
		$(this).css({'width': '200px', 'height': '200px' });
	}
	else {
		t.css({'width': '40px', 'height': '40px' });
	}
});

$(document).on('click', '.delete_ticket', function() {
	var a = $(this);
	var timestamp = Date.now();
	var uuid = a.attr('uuid');
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/delete_ticket',
			data: { timestamp: timestamp, uuid: uuid },
			success: function(response) {

				$('.ticket_holder[uuid="' + response['uuid'] + '"]').remove();
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

$(document).on('click', '.suspend_ticket', function() {
	var t = $(this);
	var timestamp = Date.now();
	var uuid = t.attr('uuid');
	$.ajax({
		url: '/manager/suspend_ticket',
		data: { uuid: uuid, timestamp: timestamp },
		success: function(response) {

			ticket_list();
			t.css({ 'background-color': 'green' });
			setTimeout(function() {
				t.css({ 'background-color': 'grey' });
			}, 1000);
		}
	});
});

$(document).on('click', '.renew_ticket', function() {
	var t = $(this);
	var timestamp = Date.now();
	var uuid = t.attr('uuid');
	var warranty = $('#ticket_warranty').val();
	$.ajax({
		url: '/manager/renew_ticket',
		data: { timestamp: timestamp, uuid: uuid, warranty: warranty },
		success: function(response) {

			ticket_list();
			t.css({ 'background-color': 'green' });
			setTimeout(function() {
				t.css({ 'background-color': 'grey' });
			},1000);
		}
	});
});

$(document).on('click', '.reinstate_ticket', function() {
	var t = $(this);
	var timestamp = Date.now();
	var uuid = t.attr('uuid');
	
	$.ajax({
		url: '/manager/reinstate_ticket',
		data: { timestamp: timestamp, uuid: uuid },
		success: function(response) {

			ticket_list();
			t.css({ 'background-color': 'green' });
			setTimeout(function() {
				t.css({ 'background-color': 'grey' });
			},1000);
		}

	});

});

$(document).on('change', '#ticket_network_device', function() {
	var t = $(this);
	var ip = t.find('option[value="' + t.val() + '"]').attr('ip');
	$('#ticket_network_ip').text(ip);

});


var searchingTimeout;
var lastSearchTime;
$(document).on('keyup click', '#search', function(e) {
	lastSearchTime = Date.now();
	var timestamp = lastSearchTime;
	var search = $(this).val();
	clearTimeout(searchingTimeout);
	searchingTimeout = setTimeout(function() {
		clearTimeout(searchingTimeout);
		$('#search').val('');
	},5000 * 60);
	if (e.keyCode != 13) {
		$.ajax({
			url: '/manager/keyup_search',
			type: 'GET',
			data: { search: search, timestamp: timestamp },
			success: function(response) {
				if (response.timestamp == lastSearchTime) {
					var o = $('#search').offset();
					var h = $('#search').height();
					if (response.count > 0) {
						$('#search_results').html(response.results).show();;
					}
					else {
						$('#search_results').html('').hide();
					}
					var height = $('#manager_search_results').height();
					$('#search_results').css({ 'position':'fixed', height: height, 'bottom': $(window).height() + $(document).scrollTop() - o.top, 'border': 'solid', 'border-width': '3px', 'text-align': 'center', 'left': o.left, 'width': $('#search').width() });
				}
			}
		});
	}
});

$(document).on('click','.manager_search_result', function() {
	var app = $(this).text();
	var timestamp = Date.now();
	appointmentGrabber(app,timestamp);
	$('#search_results').hide();
	$('#start_menu').hide();
	pseudonymHomeHider(pseudonymHIntervals);
});


$(document).on('click', '.search_toggle', function(i,e) {
	$('body').css({ 'cursor': 'progress' });
	clearTimeout(searchTimeout);
	var search = $('#search').val();
	var timestamp = Date.now();
	localStorage.setItem('lastSearchTime',timestamp);
	localStorage.setItem('search', search);
	$('#search_results').html('').hide();
	var chosen_appts = [];
	$('.appointments').each(function(i,val) {
		chosen_appts.push($(this).attr('app'));
	});
	if (search) {
		searchTimeout = setTimeout(function() {
			if ($('#search').val() == search) {
				$.ajax({
					url: '/manager/search',
					data: { search: search, timestamp: timestamp, chosen_appts: chosen_appts },
					success: function(response) {
						var res = $(response);

						var lastSearchTime = localStorage.getItem('lastSearchTime');
					//	if (res.find('.appointment').attr('timestamp') == lastSearchTime) {
							windowMaker(response);
							appointment_chron();
							$('body').css({ 'cursor': 'auto' });
					//	}
					}
				});
			}
		},1300);
	}
	else {
		$('.wind[title=search]').remove();
	}
});

$(document).on('click', '.search_engine_grabber', function() {

	var name = $(this).attr('name');
	var timestamp = Date.now();
	var search = $(this).attr('search') || $('#search').val();
	var website = $(this).attr('url') + search;
	var view = $(this).attr('view');
	$.ajax({
		url: '/manager/search_engine_grabber',
		type: 'GET',
		data: { app: name, search: search, view: view, website: website, timestamp: timestamp },
		success: function(response) {
			centreViewWriter(response);
			
		}
	});
});

$(document).on('click', '.torch_toggle', function() {
	var torch = localStorage.getItem('torch_status') || 'off';
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/torch',
		type: 'GET',
		data: { torch: torch, timestamp: timestamp },
		success: function(response) {

			localStorage.setItem('torch_status', response);
		}
	});
});




$(document).on('click','.file_toggle',function() {
	var detail = $(this).closest('.appointment_detail');
	var appointment = $(this).closest('.appointment');
	var app = appointment.attr('app');
	var file = $(this).attr('file');
	var timestamp = $(this).attr('timestamp');

	$.ajax({
		url:'/manager/file_open',
		type:'GET',
		data: { file: file, timestamp: timestamp, app: app },
		success: function(response) {

			detail.find('.detail_image').attr('src', response.filepath);

		}
	});
});

$(document).on('click', '.share', function() {
	var image = $(this);
	var src = image.attr('file');
	var type = image.attr('type');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/share',
		type: 'GET',
		data: { src: src, type: type, timestamp: timestamp },
		success: function(response) {
		}
	});
});



$(document).on('click', '.fuck_you', function() {
	fuck_you();
});

var fucks = Date.now();
function fuck_you() {
	var timestamp = Date.now();
	if (timestamp < (fucks + 1000)) {
		return;
	}
	fucks = Date.now();
	var bt = $('#browser_toggle');
	$('#search').val('');
	$.each(['#left_view','.wind', '.cord', '.manager_search_result'],function(i,v) {
		$(v).remove();
	});
	$.each(['#configure_balloon','#ide_sidebar_container','#mail_sidebar_container', '#soundroom_sidebar_container', '#grapple', '#search_results'],function(i,v) {
		$(v).hide();
	});
	$('.typewriter').remove();
	$.each(heartbeat, function(i,v) {
		clearInterval(heartbeat[i]);
	});
	websocketStop();
	mailWebSocketStop();
	inputClose();
	jpStop();
	twirlRunning = false;
	startMenuCloser(0);
	$('#start_apps').html('');
	$('#time_machine').val('');
	$('#timeshift').val('');
	$('#alert').html('').hide();
	$('.dot').hide();
	$('.window_icon').remove();
	localStorage.setItem('timeshift', '0');
	localStorage.setItem('time_machine','');
	sessionStorage.setItem('window_storage', '{}');
	var timestamp = Date.now();
	$.each(locationWatchers, function(i,v) {
	//	continent_cancel(i);
	});
	$.ajax({
		url: '/manager/fuck_you',
		type: 'POST',
		data: { timestamp: timestamp }
	});
}

$(document).on('click', '#start_menu_toggle', function() {
	startMenuToggle();
});

$(document).on('click', '.start_menu_menu', function() {
	var menu = $(this).attr('menu');
	localStorage.setItem('start_menu_menu', menu);
	$('#start_menu').attr('toggled', 'closed');
	startMenuToggle({ source: 'menu' });
});

$(document).on('click', '.jonathan, .start_menu_list', function() {
	if ($('#start_menu').is(':visible')) {
		startMenuToggle();
	}
});

function startMenuToggle(data) {
	if (typeof data == 'undefined') { data = {}; }
	var source = data['source'];
	var st = $('#start_menu_toggle');
	var start_menu = $('#start_menu');
	var menu = localStorage.getItem('start_menu_menu');
	clearTimeout(startMenuTimeout);
	if ((st.attr('toggled') == 'open' || start_menu.is(':visible')) && !source) {
		startMenuCloser(0);
		st.attr('toggled', 'closed');
		if (focused_input.is(':visible')) {
		//	focused_input.focus();
		}
	}
	else {
		$.ajax({
			url: '/manager/start_menu',
			type: 'GET',
			data: { menu: menu },
			success: function(response) {
				if (response.html) {
					console.log('in the start');
					$('#start_menu').replaceWith(response.html);
					$('#start_menu').show();
					startMenuListify();
					taskbarDisplayer();
					st.attr('toggled', 'open');
					startMenuCloser(35000);
				}
			}
		});
	//	$('#search').focus();
		}
	}

// The app menu ships as a wall of icons separated by <br>. Turn it into a list:
// each icon keeps its id and classes (the click handlers hang off those) and gains
// a text label from its hint, and the breaks in between go away. The rows are kept
// in alphabetical order and read icon first, so the icons line up in a column
// against the left edge. Safe to call again on the same markup.
function startMenuListify() {
	var main = $('.start_menu_main_display');
	if (main.length == 0) { return; }
	main.find('br').remove();
	main.find('img').each(function () {
		var img = $(this);
		if (img.closest('.start_menu_item').length > 0) { return; }
		// the leave and site-type buttons are absolutely placed in the top corner;
		// wrapping them in a row would move them
		if (/position\s*:\s*absolute/i.test(img.attr('style') || '')) { return; }
		var label = img.attr('hint') || '';
		// start_menu_list is what the other menus use for a row that closes the menu
		var item = $('<span class="start_menu_item start_menu_list"></span>');
		// The row goes at the top level of the list even when the template wrapped the
		// icon in something else (the tickets button sits in a bare <span>). Left in
		// that wrapper it is not a child of the list, so the sort never sees it and it
		// ends up stranded above the rows that were sorted.
		main.append(item);
		// icon first so it sits on the left, name beside it
		item.append(img);
		if (label) {
			item.append($('<span class="start_menu_item_text"></span>').text(label));
		}
		// the X takes the app back off the recent list; startMenuView() shows
		// it only over the recents, and the row press steps aside for it
		item.append('<span class="start_menu_recent_clear" hint="Forget">✕</span>');
	});
	startMenuSort(main);
	startMenuView();
}

function startMenuSort(main) {
	var items = main.children('.start_menu_item').get();
	if (items.length < 2) { return; }
	items.sort(function (a, b) {
		var at = ($(a).text() || '').trim().toLowerCase();
		var bt = ($(b).text() || '').trim().toLowerCase();
		if (at == bt) { return 0; }
		return at < bt ? -1 : 1;
	});
	$(items).appendTo(main);
}
// the name is part of the button: pressing it presses the icon next to it
$(document).on('click', '.start_menu_item_text', function () {
	$(this).siblings('img').trigger('click');
});

// and so is the padding around them: a tap anywhere on the row opens the app,
// rather than landing on the gap and only closing the menu
$(document).on('click', '.start_menu_item', function (e) {
	if ($(e.target).closest('.start_menu_recent_clear').length > 0) { return; }
	startMenuUseRecord($(this));
	if ((e.target.tagName || '').toUpperCase() == 'IMG') { return; }
	if ($(e.target).hasClass('start_menu_item_text')) { return; }
	$(this).find('img').first().trigger('click');
});

// What the app menu remembers: the apps opened from it, freshest first, kept
// in the president's cache and riding on the list as its recent attribute -
// the list IS the recent list, and the shelf rail is how everything else is
// reached. A press writes the app back, through the server and into the
// attribute so the view agrees without waiting. Which shelf is showing lives
// on the rail button itself, so a fresh menu - fetched on every open - always
// starts on the recents.
function startMenuRowKey(item) {
	var img = item.find('img').first();
	return img.attr('id') || img.attr('hint') || ($.trim(item.text()) || '');
}

function startMenuRowCategory(item) {
	return item.find('img').first().attr('category') || '';
}

function startMenuRecent() {
	var said = $('.start_menu_main_display').attr('recent') || '';
	return said.length ? said.split(',') : [];
}

function startMenuUseRecord(item) {
	var key = startMenuRowKey(item);
	if (!key) { return; }
	var recent = $.grep(startMenuRecent(), function (k) { return k !== key; });
	recent.unshift(key);
	$('.start_menu_main_display').attr('recent', recent.join(','));
	$.ajax({ url: '/manager/start_menu/used', type: 'POST', data: { used: key } });
}

// The X on a recent item forgets the app: it must not open it, so the press
// is stopped here, the list is rewritten without the key and the view shows
// the row gone.
$(document).on('click', '.start_menu_recent_clear', function (e) {
	e.stopPropagation();
	startMenuForget(startMenuRowKey($(this).closest('.start_menu_item')));
});

function startMenuForget(key) {
	if (!key) { return; }
	var recent = $.grep(startMenuRecent(), function (k) { return k !== key; });
	$('.start_menu_main_display').attr('recent', recent.join(','));
	$.ajax({ url: '/manager/start_menu/forget', type: 'POST', data: { forget: key } });
	startMenuView();
}

// The shelf showing narrows the list to its own, kept alphabetical; otherwise
// the list is the recents, freshest first, and the note stands in their place
// until a press has filled it.
function startMenuView() {
	var main = $('.start_menu_main_display');
	if (main.length == 0) { return; }
	var rows = main.children('.start_menu_item');
	if (rows.length == 0) { return; }
	var category = $('.start_menu_category.selected').attr('category') || '';
	rows.show();
	if (category) {
		startMenuSort(main);
		rows.each(function () {
			if (startMenuRowCategory($(this)) !== category) { $(this).hide(); }
		});
	}
	else {
		var rank = new Map();
		$.each(startMenuRecent(), function (i, key) {
			if (!rank.has(key)) { rank.set(key, i); }
		});
		var order = [];
		rows.each(function () {
			if (rank.has(startMenuRowKey($(this)))) { order.push(this); }
			else { $(this).hide(); }
		});
		order.sort(function (a, b) { return rank.get(startMenuRowKey($(a))) - rank.get(startMenuRowKey($(b))); });
		$(order).appendTo(main);
	}
	var shown = rows.filter(function () { return $(this).css('display') != 'none'; }).length;
	main.find('.start_menu_empty').toggle(!category && shown == 0);
	rows.find('.start_menu_recent_clear').toggle(!category);
}

// A press on a shelf shows it, a press on the shelf showing brings the
// recents back; the button wears the choice, and the next open - a fresh
// menu with no shelf marked - lands on the recents again.
$(document).on('click', '.start_menu_category', function () {
	var showing = $(this).hasClass('selected');
	$('.start_menu_category').removeClass('selected');
	if (!showing) { $(this).addClass('selected'); }
	startMenuView();
});

// the menu ships inside the page as well as over the socket, so do it once at load
$(function () { startMenuListify(); });

function startMenuCloser(wait) {
	clearTimeout(startMenuTimeout);
	startMenuTimeout = setTimeout(function() {
		var start_menu = $('#start_menu');
		if ($('#start_menu').is(':visible')) {
			var m = mouse_position();
			var left = start_menu.offset().left;
			var top = start_menu.offset().top;
			var height = start_menu.height();
			var width = start_menu.width();
			if (wait == 0 || !((m.x > left && m.x < (left + width)) && (m.y > top && m.y < (top + height)))) {
				var st = $('#start_menu_toggle');
				st.attr('toggled', 'closed');
				start_menu.hide();
			}
			else {
				startMenuCloser(7000);
			}
		}
	},wait);
}

function htopViewer() {
	if ($('#htop_viewer').is(':visible')) {
		$.ajax({
			url: '/manager/start_menu/htop_viewer',
			type: 'GET',
			success: function(response) {
				$('#htop_viewer').replaceWith(response.html);
				appointment_chron();

			}
		});
	}
}

$(document).on('click', '#browser_toggle', function() {
	var bt = $(this);
	if ($('#browser').is(':visible')) {
		$('#browser').hide();
		bt.css({'border-color': 'black' });
	} else {
		$('#browser').show();
		bt.css({'border-color': 'yellow' });
	}
});


$(document).on('click', '.main_image_selector', function() {
	var file = $(this).attr('file');
	var app = $(this).attr('app');
	var selected = $(this).attr('main_image');
	var mis = $('.main_image_selector');
	mis.attr('main_image', 'no');
	mis.css({'border-color': 'black','border-width':'3px'});

	if (selected == 'yes') {
		settingDeleter({ 'app': app, 'setting': 'main_image' });
	}
	else {
		settingSetter({ 'app': app, 'setting': 'main_image', 'value': file });
		$(this).css({'border-color':'orange','border-width':'6px'});
		$(this).attr('main_image', 'yes');
	}
});

var cb_check = 0;
$(document).on('click', '.configuration', function() {
	configureToggle()
});

$(document).on('click','.purchase', function() {
	var iq = $(this).closest('.appointment').find('.purchase_details');
	if (iq.is(':hidden')) { 
		iq.show(); 
		timestampDater();
    iq.find('.date').val(moment(Date.now()).format('M/D/YYYY'));
	}
	else { iq.hide(); }
});
$(document).on('click','.inventory', function() {
	var iq = $(this).closest('.appointment').find('.inventory_details');
	var app = $(this).closest('.appointment').attr('app');
	if (iq.is(':hidden')) {
		iq.show();
		inventoryDetails(app);
	}
	else {
		iq.hide(); 
	}
});


var backy_color = 0;
$(document).on('keyup', '.timed_input', function(e) {
	if (e.keyCode == 13) {
		var url;
		var i = $(this);

		var id = i.attr('id');
		var messaging = i.attr('messaging');
		var value = i.val();
		var timestamp = Date.now();
		var time_machine = localStorage.getItem('time_machine');
		var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
		var project = localStorage.getItem('project');
		var data;
		var type = 'POST';
		var timeout = 3000;

		if (i.hasClass('add_something') || i.hasClass('.time_machine')) {
			clearTimeout(searchTimeout);
			setTimeout(function() {
				$('#search_results').html('').hide();
			},700);
			i.addClass('active');
			url = '/manager/reset';
			var entry = 'add';
			data = { app: value, timeshift: timeshift, timestamp: timestamp, type: entry, movement: 'expense', time_machine: time_machine, project: project };
			timeout = 1000;
		}
		else if (i.hasClass('name_change')) {
			url = '/manager/configure';
			var setting = i.attr('setting');
			var app = i.attr('app');
			var name = i.val();
			data = { app: app, timestamp: timestamp, type: setting, setting: setting, value: value };
		}
		else if (i.hasClass('appointment_search')) {
			url = '/manager/appointment_details',
			type = 'GET';
			data = { app: value, timeshift: timeshift, timestamp: timestamp, type: "search", time_machine: time_machine,  scope: scope };	
		}
		if (url) {
			$.ajax({
				url: url,
				type: type,
				data: data,
				success: function(response) {
					if (i.hasClass('add_something') || url == '/manager/configure') {
						$('#start_menu').hide();
						i.removeClass('active');
						centreViewWriter(response.cv);
				//		configureDisplay();
						appointment_chron();
					//	$('#search').val('');
						if ($('.now').attr('presence') != 'not' && response['added'] == 'yes') {
								continent_record({'uuid':response['uuid'],'purpose': 'app','app':response['app'],'timestamp':response['timestamp']});
							}
					}
					i.css({ "background-color": "yellow" });
					clearTimeout(backy_color);
					backy_color = setTimeout(function() {
						i.css({ "background-color": "white" });
					},950);
				}
			});
		}
	}
});

$(document).on('click','.voice_prompt',function() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/voice_prompt',
		data: { timestamp: timestamp, repeater: 'no' },
		success: function(res) {


		},
		error: function(err) { console.log("adder error",err); }
	});
});

$(document).on('dblclick', '.voice_prompt', function() {

	$.ajax({
		url: '/manager/voice_prompt',
		data: { timestamp: timestamp, repeater: 'yes' },
		success: function(res) {

		},
		error: function(err) { console.log("adder error",err); }
	});
});

function said_it(text) {
	if (focused_input.not(':visible')) {
		focused_input = $('#search');
	}


	if (text) {
		if (focused_input.attr('id') == 'search' || typeof focused_input == "undefined") {
			$('#search').val(text);
			$('#search').trigger(jQuery.Event('keyup', { keyCode: 13 }));
		}
		else {
			var pretext = focused_input.val();
			if (pretext) {
				pretext += '. ';
			}
			focused_input.val(pretext + text);
			focused_input.trigger('keyup');
		//	focused_input.trigger(jQuery.Event('keyup', { keyCode: 13 }));
		}
	}

}

$(document).on('click', '.appointment_list_toggle', function() {
	var list = $(this).attr('list');
	var l = $(this).closest('.appointment_detail').find('.appointment_list[list="' + list + '"]');
	if (l.is(':visible')) {
		l.hide();
	}
	else {
		l.show();
	}

});
$(document).on('click', '.delete_duty', function() {
	var a = $(this);
	var duuid = a.attr('duuid');
	var server_time = a.attr('server_time');
	var app = a.closest('.appointment').attr('app');
	var app_uuid = a.closest('.appointment_detail').attr('uuid');
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/delete_duty',
			type: 'POST',
			data: { duuid: duuid, server_time: server_time, app: app, app_uuid: app_uuid },
			success:function(response) {

				$('.appointment_duty_container[duuid="' + response.duuid + '"]').remove();
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

$(document).on('click', '.download', function() {
	var d = $(this);
	var file = d.attr('file');
	var uuid = d.attr('uuid');
	var app = d.attr('app');
	var server_time = d.attr('server_time');
	var timestamp = d.attr('timestamp');
	var uri = encodeURIComponent(app);
	window.location='/manager/download_file?app=' + uri + '&uuid=' + uuid + '&timestamp=' + timestamp + '&server_time=' + server_time + '&file=' + file;
});

$(document).on('click', '.take_picture', function() {
	var d = $(this).closest('.appointment_detail');
	var app = d.attr('app');
	var uuid = d.attr('uuid');
	var camera = $(this).attr('camera');
	var container = d.closest('.appointment');
	var timestamp = Date.now();
	var ago = container.find('.ago').val();
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	$.ajax({
		url: '/manager/take_picture',
		type: 'POST',
		data: { app: app, uuid: uuid, camera: camera, timestamp: timestamp, ago: ago, time_machine: time_machine, timeshift: timeshift },
		success: function(response) {

		}
	});
});

$(document).on('click', '.scan_document', function() {
	var d = $(this).closest('.appointment_detail');
	var container = d.closest('.appointment');
	var app = d.attr('app');
	var uuid = d.attr('uuid');
	var feed = $(this).attr('feed');
	var timestamp = Date.now();
	var ago = container.find('.ago').val();
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	$.ajax({
		url: '/manager/scan_document',
		type: 'POST',
		data: { app: app, uuid: uuid, feed: feed, timestamp: timestamp, ago: ago, time_machine: time_machine, timeshift: timeshift },
		success: function(response) {

		}
	});
});

var m;
var main_h;
$(document).on('click', '.upload_file, #upload', function(e) {
	var b = $(this);
	var m =	$('#main_upload_input');

	var app = undefined;
	var uuid = undefined;
	var source = 'main_upload';
	
	if (b.hasClass('app_upload')) {
		app = b.closest('.appointment_detail').attr('app');
		uuid = b.closest('.appointment_detail').attr('uuid');
		source = 'app_upload';
	}
	m.attr('app', app);
	m.attr('uuid', uuid);
	m.attr('source', source);
	main_h = $('#main_upload_container').html();
	m.trigger('click');
});

$(document).on('change', '#main_upload_input', function() {
	var m =	$('#main_upload_input');
	
//	m.trigger('click');

	$.each(m[0]['files'], function(i,v) {

	});
	if (m[0]['files'].length > 0) {
		$('#main_upload').trigger('submit');
	}
});

$(document).on('submit', "#main_upload", function(e) {
  e.preventDefault();
	var mui =	$('#main_upload_input');
  var formData = new FormData(this);
	formData.delete('timestamp');
	formData.append('timestamp', timestamp);
	var apper = $('.wind[app="' + topWindow() + '"]');
	var navigation = $(apper).attr('navigation');
	app = $(apper).attr('app') || $('#search').val();
	formData.delete('app');
	formData.delete('uuid');
	var source = mui.attr('source');
	if (source == 'app_upload') {
		app = mui.attr('app');
		var uuid = mui.attr('uuid');
		formData.append('uuid', uuid);
	}

	formData.append('app', app);
	formData.append('source', source);
  $.ajax({
      url: '/manager/upload_file',
      type: 'POST',
      data: formData,
      success: function (response) {
				m = undefined;
				formData.delete('fileupload');
				$('#main_upload').remove();
				$('#main_upload_container').html(main_h);
				appClearer(app);
				continent_record({'uuid':response['uuid'],'purpose':'app','app':response['app'],'timestamp':response['timestamp'],'navigation':navigation});
      },
      cache: false,
      contentType: false,
      processData: false
  });
});

$(document).on('click', '.name_text', function(){
	var text = $(this).text();
	focused_input.val(text);
});

$(document).on('click','.app_act, .save_appointment',function() {
	var b = $(this);
	var app = b.attr('app') || b.closest('.appointment').attr('app');
	var originalColour = b.css('background-color');
	b.css({'background-color': 'blue'});
	setTimeout(function() { b.css({'background-color': originalColour }); },750);
//	cacheDelete({ app: app, context: 'template' });
});

// the appointment's three group buttons each open the buttons they carry
// beneath them; opening one folds the others away, so the row under the
// groups always answers the button just pressed
$(document).on('click', '.group_toggle', function() {
	var group = $(this).attr('group');
	var appointment = $(this).closest('.appointment');
	var contents = appointment.find('.' + group + '_group_contents');
	var open = contents.is(':visible');
	appointment.find('.group_contents').hide();
	if (!open) { contents.show(); }
});

$(document).on('click','#calculate_it', function() {
	clearInterval(calculateInterval);
	calculator();
});

$(document).on('click, change', '#update_frequency', function() {
	var f = $(this).val();
	localStorage.setItem('update_frequency', f);
	initializer()
});




$(document).on('click', '#timeshift_viewer', function() {
	var time_machine = $('#timeshift_viewer').text() + ' ' + $('#time_machine').val();
	$('#time_machine').val(time_machine);
	localStorage.setItem('time_machine',time_machine);
});

// Back to the present: the now button and a double-click on the canvas both
// come through here. Any glide or pending flick is stopped first - it would
// write the time machine back the moment it landed and undo this.
function nowResetter() {
	cancelAnimationFrame(clothesLinePos['timelineSmoothScrolling']);
	clothesLinePos['timelineSmoothScrolling'] = undefined;
	if (clothesLinePos['fling']) {
		clearTimeout(clothesLinePos['fling']['settle']);
		clothesLinePos['fling'] = undefined;
	}
	// and stand the drag state down, or calculator() sees the view as just moved
	// and declines to fetch the present back
	clothesLinePos['moving'] = 0;
	clothesLinePos['lastBX'] = undefined;
	clothesLinePos['mouseDrag'] = 0;
	clothesLinePos['startMove'] = undefined;
	$('#time_machine').val('');
	$('#timeshift').val('');
	localStorage.setItem('timeshift', '0');
	localStorage.setItem('time_machine','');
	localStorage.setItem('timeshift', '');
	timestamp = Date.now();
	initializer();
	debrief_setter();
	calculator();
}

$(document).on('click','.now',function() {
	nowResetter();
});



var note_typing_timeout;
$(document).on('keyup', '.notes, .ago, .duration', function() {
	var i = $(this);
	var app = i.closest('.appointment');
	var appointment = app.attr('app');
	clearTimeout(note_typing_timeout);
	note_typing_timeout = setTimeout(function() {
		$.each(['notes','ago','duration'], function(io,v) {
			var input = app.find('.' + v);
			var typed = input.val();
			if (input.hasClass('text_editor') && input.hasClass(v)) {
				typed = input.html();
			}
			if (typed && typed != '' && typed != '<br>') {
				localStorage.setItem(appointment + '_' + v, typed);
			}
			else {
				localStorage.removeItem(appointment + '_' + v);
			}
			input.trigger('change');
		});
		i.css({ "background-color": "yellow" });
		clearTimeout(backy_color);
		backy_color = setTimeout(function() {
			i.css({ "background-color": "white" });
		},750);
	},200);
});


$(document).on('focus, click', 'input.time', function() {
	$(this).addClass('editing');
});

$(document).on('change, focusout', 'input.time', function() {
	var input = $(this);
	var time = input.val();
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/ago',
		type: 'GET',
		data: { ago: time },
		success: function(response) {
			input.attr('timestamp', response);
			input.removeClass('editing');
			if (input.attr('setting') && input.attr('app')) {
				settingSetter({'app': input.attr('app'), 'setting': input.attr('setting'), value: response });
			}
		}
	});
});




$(document).on('dblclick', '#timeshift', function() {
	var e = $(this);
	var scope = e.val();
	e.val(0);
	localStorage.setItem('timeshift', 0);
	debrief_setter();
});

var timeshift_timeout;
$(document).on('input', '#timeshift', function() {
	var timeshift = $(this).val();
	localStorage.setItem('timeshift', timeshift);
	if ($('.appointment_details').is(':visible') ) {
		$('.appointment_details').each(function(i,v) { 
			$(v).closest('.appointment').find('.det').trigger('dblClick');
		});
	}
	debrief_setter();
	clearTimeout(timeshift_timeout);
	setTimeout(function() {
		calculator();
	},10);
});

$(document).on('change', '#timeshift_scope', function() {
	var timeshift = $(this).val();
	localStorage.setItem('timeshift_scope', timeshift);
	var scope = 12;
	if (timeshift == 'h' ||timeshift == 'm'||timeshift == 's') { scope = 60 }
	if (timeshift == 'y') { scope = 20 }
	$('#timeshift_max').attr('max', scope );
	debrief_setter();
});

$(document).on('change', '#scope', function () {
	var scope = $(this).val();
	localStorage.setItem('scope', scope);
	debrief_setter();
});

$(document).on('change', '#filter', function () { 
	var filter = $(this).val();
	localStorage.setItem('filter', filter);
	debrief_setter()
});

$(document).on('change', '#layout', function() {
	var layout = $(this).val();
	localStorage.setItem('layout', layout);
	debrief_setter();
});

$(document).on('change', '#projects', function() {
	var project = $(this).val();
	localStorage.setItem('project', project);
	debrief_setter();
});

$(document).on('change', '#accounts', function() {
	var account = $(this).val();
	localStorage.setItem('account',account);

	debrief_setter();
});
$(document).on('change', '#background_images', function() {
	var bgi = localStorage.getItem('background_images');
	if (bgi == 'on') {
		bgi = 'off';
	}
	else {
		bgi = 'on';
	}
	localStorage.setItem('background_images', bgi);
	debrief_setter();
});
$(document).on('change', '#background_images_opacity', function() {
	var bgi = $(this).val();
	localStorage.setItem('background_images_opacity', bgi);
	$('#background').css({ 'opacity': bgi });
	debrief_setter();
});

$(document).on('change', '#sorts', function() {
	var sorts = $(this).val();
	localStorage.setItem('sorts', sorts);
	debrief_setter();
});

$(document).on('click','#appt_view_toggle', function() {
	var view = $(this);
	if (sessionStorage.getItem('appt_view_toggle') == 'on') {
		sessionStorage.setItem('appt_view_toggle', 'off')
		localStorage.setItem('appt_view_toggle', 'off');
		view.css({ 'background-color': '' });
	}
	else {
		view.css({ 'background-color': 'green' });
		sessionStorage.setItem('appt_view_toggle', 'on');
		localStorage.setItem('appt_view_toggle', 'on');
	}

});
var appts = {};
var response = {};
function deloreanBringer() {
	var now = Date.now();
	var readable = moment(now).format();
	var appts = []
	$('.appointment').each(function(n,v) {
		var v = $(this);
		if (v.is(':visible')){ appts.push(v.attr('app')); }
	});
	
	var appointments = JSON.stringify(appts);
	if (appts.length == 0 || sessionStorage.getItem('appt_view_toggle') != 'on') {
		appointments = [];
	}
	var timeshift = localStorage.getItem('timeshift');
	var timeshift_scope = localStorage.getItem('timeshift_scope');
	timeshift = timeshift + timeshift_scope;
	var scope = localStorage.getItem('scope');
	var sorts = localStorage.getItem('sorts');
	var layout = localStorage.getItem('layout');
	var filter = localStorage.getItem('filter');
	var project = localStorage.getItem('project');
	var account = localStorage.getItem('account');
	var background_images = localStorage.getItem('background_images');
	var background_images_opacity = localStorage.getItem('background_images_opacity');
	var time_machine = localStorage.getItem('time_machine');
	var appt_view_toggle = sessionStorage.getItem('appt_view_toggle') || localStorage.getItem('appt_view_toggle');
	return { 
		timestamp: now, 
		readable: readable,
		appts: appointments,
		scope: scope,
		sorts: sorts,
		layout: layout,
		filter: filter,
		timeshift: timeshift,
		time_machine: time_machine,
		account: account,
		project: project,
		appt_view_toggle: appt_view_toggle,
		background_images: background_images,
		background_images_opacity: background_images_opacity,
		now: now
	};
}
function calculator() {
	var now = Date.now();

	if (document.visibilityState == 'visible' && !document.hidden && clothesLinePos['moving'] + 300 < now && clothesLinePos['lastBX'] == undefined) {
		var data = deloreanBringer();
		windowBackgroundAdjuster({ caller: 'calculator' });
		if (appts['__specs']) {
			if ((now - 35000) > appts['__specs']['server_time']) {
				if (!data['stats']) { data['stats'] = {}; data['stats']['appts'] = {}; data['stats']['settings'] = {}; } 
				data['stats']['appts']['first'] = appts['__specs']['stats']['appts']['first'];
				data['stats']['appts']['last'] = appts['__specs']['stats']['appts']['last'];
				data['stats']['settings']['first'] = appts['__specs']['stats']['settings']['first'];
				data['stats']['settings']['last'] = appts['__specs']['stats']['settings']['last'];
				data['stats']['appts']['count'] = appts['__specs']['stats']['appts']['count'];
				data['stats'] = JSON.stringify(data['stats']);
			}
		}

		$.ajax({
			url:'/manager/appointment_viewer',
			type:'GET',
			data: data,
			success: function(respons){
				if (respons.updateable != 'no') {
					now = Date.now();

					if (clothesLinePos['moving'] + 300 < now && clothesLinePos['lastBX'] == undefined) {
						appts = respons.appts;
					//	appts = { ...appts, ...response.appts };
						var pseudonyms = respons.pseudonyms;
						$('.time_jump').each(function(i,v) {
							$(v).attr('timestamp',respons.timestamp);
						});
						var ts = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');

						graphicalize(respons);
					//	inventoryDetailsUpdater();
					}
				}
				else {
					// nothing new was fetched: the view slides to the centre the server
					// names - exactly, and only from rest. The flick's ~32x reach belongs
					// to a gesture and not to a correction: added here it flew past the
					// target, and the next poll flew the whole error again, 32x larger,
					// until the dates left the calendar behind.
					now = Date.now();
					if (clothesLinePos['moving'] + 300 < now && clothesLinePos['lastBX'] == undefined) {
						timestamp = respons['__specs']['timestamp'];
						timelineScroller({ diff: (response.appts['__specs']['timestamp'] - respons['__specs']['timestamp']), source: 'slide' });
						response['__specs'] = respons['__specs'];
					}
				}
			}
		});
	}
}

$(document).on('click', '#web_toggle,.web_toggle', function() {
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/web',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			windowMaker(response);
		}
	});


});

$(document).on('click', '.web', function() {
	var app = $(this).attr('app');
	var website = $(this).attr('web');
	var uuid = $(this).attr('uuid');
	var ts = timestamp;
	if (uuid) {
		ts = $(this).closest('.wind').attr('timestamp');
	}
	var user_agent =   navigator.userAgent; 
	$.ajax({
		url: '/manager/website_get',
		data: { app: app, website: website, timestamp: ts, user_agent: user_agent, uuid: uuid },
		success: function(response) {
			var ls = localStorage;
			var ss = sessionStorage;
			if (!uuid) {
			//	$('#browser').append(response.window);
				var window_id = windowMaker(response.window);
			}
			ts = $('.wind[app="web"]').attr('timestamp');
			uuid = response.uuid;
			$('#browser_' + ts).remove();
			$('<iframe>', {
				src: '/manager/browser?internal_url=' + response.internal_url + '&timestamp=' + ts + '&app=' + app + '&uuid=' + uuid,
				id:  'browser_' + ts,
				frameborder: 0,
				scrolling: 'yes',
				style: "width:100%;height:calc(100% - 50px);position:absolute;top:90px;"
			}).appendTo('#window_contents_' + ts);
			$('#browser_' + ts).css({'background-color': 'white'}).addClass('web_browser_iframe').show();
			$('#website_title').text(response.app);
			$('#website_time').attr('timestamp', response.timestamp);
			$('#web').hide();
			$('#web_measure_toggle').attr('uuid', uuid).attr('app', app).show();
			appointment_chron();


			$('#browser_' + ts).on('load', function() {
				$(this).contents().find('body').on('mousemove', function(event) {
					var bs = $('#browser_' + ts);
					if (bs.hasClass('measure_selector_enabled')) {
						var selector = selectorMaker(event.target);
						var t = bs.find(selector).html();
					}
				});
				$(this).contents().find('body').on('click', function(event) {
					if ($('#browser_' + ts).hasClass('measure_selector_enabled')) {
						var selector = selectorMaker(event.target);
						var text = $(event.target).text();

						var measure = $('#web_measure_selector').val();
						$.ajax({ 
							url: '/manager/web/measure/set',
							type: 'post',
							data: { app: app, uuid: uuid, selector: selector, measure: measure, text: text },
							success: function(response) {
								$('#alert').html(response.confirmation).show();
							}
		
						});
					}
				});
			});
			var ls2 = localStorage;
			var ss2 = sessionStorage;
			$.each(ls2, function(i,v) {
				if (!ls[i]) {
					localStorage.removeItem(i);
					console.log('Removed ' + i);
				}
			});
			$.each(ss2, function(i,v) {
				if (!ss[i]) {
					sessionStorage.removeItem(i);
					console.log('Removed ' + i);
				}
			});
			if (!ls2['time_machine']) {
				localStorage.setItem('timestamp', '');
			}
			if (!ls2['timeshift']) {
				localStorage.setItem('timeshift', 0);
			}
		}
	});
});

$(document).on('click', '.web_measure_confirm_item', function() {
	var b = $(this);
	var selected = b.hasClass('selected');
	var type = $(this).attr('type');
	$('.web_measure_confirm_item[type="' + type + '"]').removeClass('selected');
	if (selected) {
		b.removeClass('selected');
	}
	else {
		b.addClass('selected');
	}
});

$(document).on('click', '#web_measure_confirm_save', function() {

	var exact = $('.web_measure_confirm_item.selected[type="exact');
	var count = exact.attr('count');
	var row = exact.closest('.web_measure_confirm_row');
	var app = row.attr('app');
	var measure = row.attr('measure');
	var prev = $('.web_measure_confirm_item.selected[type="prev').attr('text');
	var next = $('.web_measure_confirm_item.selected[type="next').attr('text');
	var selector = $('#web_measure_confirm_selector').text();
	$.ajax({
		url: '/manager/web/measure/submit',
		type: 'POST',
		data: {
			app: app,
			measure: measure,
			count: count,
			prev: prev,
			next: next,
			selector: selector
		},
		success: function(response) {
			$('#alert').hide();
		}
	});
});


$(document).on('click', '#web_measure_toggle', function() {
	var t = $(this);
	var app = t.attr('app');
	var uuid = t.attr('uuid');
	var tog = t.attr('toggle');
	var timestamp = $('#website_time').attr('timestamp');
	var wms = $('#web_measure_selector')
	wms.html('')
	wms.hide();
	if (tog == 'on') {
		tog = 'off';
		t.css({'background-color': ''});
		$('#window_content_' + timestamp).removeClass('web_measurable');
		$('.web_browser_iframe').removeClass('measure_selector_enabled');
	}
	else {
		tog = 'on';
		$.ajax({
			url: '/manager/web/measure/toggle',
			type: 'GET',
			data: { app: app, uuid: uuid },
			success: function(response) {
				t.css({'background-color': 'yellow'});
				$('#window_content_' + timestamp).addClass('web_measurable');
				var count = 0;

				$.each(response.measures, function(i,v) {
					var h = '<option value="' + i + '">' + v.formatted + '</option>';
					if (count == 0) {
						h = '<option selected value="' + i + '">' + v.formatted + '</option>';
					}
					$('#web_measure_selector').append(h).show();
					if (count == 0) {
						$('#web_measure_selector').val(i);
					}
					count++;
				});
				if (count > 0) {
					$('.web_browser_iframe').addClass('measure_selector_enabled');
				}

			}
		});
	}
	t.attr('toggle', tog);
});

$(document).on('click','.web_delete', function() {
	var b = $(this);
	var app = b.attr('app');
	var uuid = b.attr('uuid');
	var armed = b.attr('armed');


	if (armed == 'yes') {
		b.addClass('superactive');
		$.ajax({
			url: '/manager/web/delete',
			type: 'POST',
			data: { app: app, uuid: uuid },
			success:function(response) {
				$('.web_history[app="' + app + '"][uuid="' + uuid + '"]').remove();
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


var ap;
var clockInterval;

function graphicalize(respons) {
	var ts = Date.now();
	
	if (!respons) {
		respons = response;
	}
	else {
		response = respons;
	}
	if (respons.clothesline.length == 0) {
		clothesLineHeight = 0;
	}
	else {
		clothesLineHeight = 40;
	}
	appts = respons.appts;

	timestamp = appts['__specs']['timestamp'];
	if ($('#' + localStorage.getItem('layout')).length == 0) {
		return;
	}
	// a row outside the drawn window is kept out to the fetched edge instead: the
	// server reaches a span past the left edge so a row just behind it can stick
	// there, and carries the row of a still-running appointment however old it
	// is, and those rows are the ones the left edge is holding on to
	var fetch_start = appts['__specs']['fetch_start'];
	if (fetch_start == undefined) { fetch_start = appts['__specs']['start']; }
	$.each(appts, function(i,v) {
		$.each(v['list'], function(am,way) {
			if (way != undefined) {
				if (way['timestamp'] && way['timestamp'] >= fetch_start && way['timestamp'] <= appts['__specs']['end']) {
				}
				else {
					appts[i]['list'].splice(am, 1);
					if (appts[i]['list'].length == 0) {
						delete appts[i];
					}
				}
			}
		});

	});
	var diff = Math.abs(timestamp - ts);
	var nowb = $('.now');
	if (diff > 1100) {
		nowb.attr( 'presence', 'not' );
		nowb.css({'background-color': 'red' });
		if (ts != timestamp) {

			nowb.css({'background-color': 'orange' });
		}
	}
	else if (diff <= 1100 && diff >= 500) {
		nowb.css({'background-color': 'yellow' });
		nowb.attr('presence', 'delayed');
	}
	else {
		nowb.attr('presence', 'here');
		nowb.css({'background-color': 'green' });
	}
	var layout = localStorage.getItem('layout');
	var timeshit = localStorage.getItem('timeshift');
	var time_machine = localStorage.getItem('time_machine');
	var background_images = localStorage.getItem('background_images');

	if (time_machine == '0s' || time_machine == 'in 0s') {
		$('#time_machine').val('');
		localStorage.setItem('time_machine', '');
		time_machine = '';
	}
	// the tile carries the time machine's state itself now that the background
	// carries the server's speed (an older universal.js just keeps its icon)
	if (typeof nowIconApply == 'function') { nowIconApply(time_machine != '' ? 'time_machine' : 'here'); }

	//guests.push(appts);
	$.each(['leaderboard', 'clockface', 'timeline', 'calendar', 'continent', 'narrator'], function(i,v) {
		if (v != layout)
			$('#' + v).hide();
	});
	if (layout == 'clockface'){
		clockfacePrinter(appts);
	}
	else if (layout == 'leaderboard') {
		leaderboardPrinter(appts);
	}
	else if (layout == 'calendar') {
		calendarPrinter(appts);
	}
	else if (layout == 'narrator') {
		narratorPrinter(appts);
	}
	else if (layout == 'timeline') {
		timelinePrinter(appts);
	}
	else if (layout == 'continent') {
		continentPrinter(appts);
	}
	if (background_images == 'on') {
		backgroundPrinter(appts,respons);
	}
	else {
		$('#background').hide();
	}
	var json_appts = JSON.stringify(appts);
	sessionStorage.setItem('appts', json_appts);

	clotheslineHanger(respons.clothesline);
}

var page_number = 0;
$(document).on('click', '#marker_toggle', function() {
	var timestamp = Date.now();
	var app = topWindow('marker');
	var url = '/manager/marker';
	if ($('#marker_toolbox').length > 0) {
		var mid = $('#marker_toolbox').closest('.wind').attr('id');
		$('#' + mid).show();
		topLevelNow($('#' + mid));
	}
	else {
		$.ajax({
			url: url,
			type: 'GET',
			data: { window_maker: 'yes', app: app, timestamp: timestamp, browser_tab_id: bti },
			success: function(response) {
				windowMaker(response);
				markerInit();
			}, error: function (response) {  }
		});
	}
});

$(document).on('click', '#terminal_toggle', function() {
	terminalOpener({ window_maker: 'yes' });
});

$(document).on('click', '#twirl_toggle', function() {
	twirlRunning = false;
	var url = '/manager/twirl';
	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response)
		}, error: function (response) {  }
	});
});



$(document).on('click', '#home_toggle', function() {
	var url = '/manager/home';

	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response);
		}, error: function (response) { }
	});
});

$(document).on('click', '#store_toggle', function() {
	storeOpener();
});

$(document).on('click', '#handbook_toggle', function() {

	var url = '/manager/handbook/' + localStorage.getItem('handbook_chapter');
	var page = localStorage.getItem('handbook_page');
	var window_saver = sessionStorage.getItem('window_storage');
	var open_windows = JSON.parse(window_saver) || {};
	var timestamp = Date.now();
	$.ajax({
		url: url,
		data: { page: page, windows: window_saver },
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response)
		}, error: function (response) { 
		}
	});
});

$(document).on('click', '.handbook_link', function() {
	var chapter = $(this).attr('chapter');
	var page = $(this).attr('page');
	var type = $(this).attr('type');
	handbookGrabber(chapter,page,type);
});

function handbookGrabber(chapter,page,type) {
	localStorage.setItem('handbook_page', page);
	var url = '/manager/handbook/' + chapter;
	var window_saver = sessionStorage.getItem('window_storage');
	var open_windows = JSON.parse(window_saver) || {};
	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp, page: page, type: type, windows: window_saver },
		success: function(response) {
			windowMaker(response)
		}, error: function (response) { 
		}
	});
}

$(document).on('click', '.handbook_setting', function() {
	var a = $(this);
	var app = a.attr('app');
	var setting = a.attr('setting');
	var value = a.attr('value');

	$.ajax({
		url: '/manager/handbook/settings',
		type: 'POST',
		data: { app: app, setting: setting, value: value },
		success: function(response) {
			a.attr('value', response[app]);
		}
	});


});

function openApps() {
	var apps = [];
	$('.appointment').each(function(i,v) {
		  apps.push($(v).attr('app'));
	});
	return apps;
}

$(document).on('click', '.top_navbar, .neighbour_window, .room_appt', function(e) {
	var clicker = $(this);
	var win = clicker.closest('.wind');
	var text = $(this).attr('app');
	if ($(e.target).parent().hasClass('navbar_buttons')) { return false; }

	var app = JSON.stringify({ name: text });
	var timestamp = Date.now();
	if (text == 'music' ) {
		var music_window = $('#music').closest('.wind').attr('id');
		topLevelNow($('#' + music_window));
	}
	else if (text == 'video') {
		var video_window = $('#video').closest('.wind').attr('id');
		topLevelNow($('#' + video_window));
	}
	else if ( text == 'gallery' ) {
		var wind = win.attr('id');
		topLevelNow($('#' + wind));
	}
	else if (text == 'marker') {
		var wind = $('#marker').closest('.wind').attr('id');
		topLevelNow($('#' + wind));
	}
	else if (text == 'mailbox') {
		var wind = $('#marker').closest('.wind').attr('id');
		topLevelNow($('#' + wind));
	}
	else if (text == 'terminal') {
		var wind = $('#terminal').closest('.wind').attr('id');
		topLevelNow($('#' + wind));
	}
	else {
		var wind = $('#terminal').closest('.wind').attr('id');
		topLevelNow(win);
	}
	if ($('.wind[app="' + text +'"]').length == 0) {
		appointmentGrabber(text,Date.now());
	}

});

$(document).on('click', '.reset', function() {
	var appointment = $(this).closest('.appointment');
	var app = appointment.attr('app');
	var details = appointment.find('.app_details');
	if (details.is(':visible')) {
		details.hide();
	}
	else {
		details.show();
	}

});

function projectAccountGrabber(details) {
	var container = details.closest('.appointment');
	var form = container.find('.app_details');
	former = form;
	var account = form.find('.account').val();
	var project = form.find('.project').val();
	var movement = form.find('.movement').val();
	var current_project = localStorage.getItem('project');

	if (current_project != 'all') {
		project = current_project;
	}
	return { account: account, project: project, movement: movement };
}

var appointmentLockingMechanism;
$(document).on('click', '.appointment_locking_mechanism', function() {
	var alm = $(this);
	var status = alm.attr('status');
	clearInterval(appointmentLockingMechanism);
	if (status == 'on') {
		alm.css({'background-color':'lightgrey'});
	}
	else {
		status = 'on';
		alm.css({'background-color':'red'});
		appointmentLockingMechanism = setTimeout(function() {
			alm.attr('status','off');
			alm.css({ 'background-color': 'lightgrey'});
		},4000);
	}
	alm.attr('status', status);
});

var former;
$(document).on('click', '.save_appointment', function(e) {
	managerReset($(this),e);
});


function managerReset(caller,e) {
	var lockingStatus = 'off';

	var details = caller;
	var pa = projectAccountGrabber(details);
	var app = details.attr('app');
	var container = details.closest('.appointment');
	var form = container.find('.app_details');
	former = form;
	if (container.find('.appointment_locking_mechanism').attr('status') == 'on' || e.ctrlKey == true) {
		lockingStatus = 'on';
	}
	var project = pa['project'];
	var movement = pa['movement'];

	var club = form.find('.club').val();
	var camera = details.attr('camera');
	var feed = details.attr('feed');
	var digits = details.attr('digits');
	var item = form.find('.item').val();
	var amount = form.find('.amount').val();
	var ago = $('#ago').val() || container.find('.ago').val();
	var duration = container.find('.duration').val();
	var schedule = container.find('.schedule').val();
	var quantity = container.find('.main_input.quantity').val();
	var notes = container.find('.text_editor').html();
	var now = Date.now();
	var type = details.attr('type');
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	var warranty = container.find('.warranty').val();
	var navigation = container.attr('navigation');
	var measure_is_open = false;

	if (container.find('.re_measures').is(':visible')) {
		measure_is_open = true;
	}

	if (type == 'stop') {
		continent_cancel(app);
	}
	var data = { 
		app: app, 
		timestamp: now, 
		type: type, 
		ago: ago,
		duration: duration,
		warranty: warranty,
		project: project,
		amount: amount,
		item: item,
		notes: notes,
		time_machine: time_machine,
		timeshift: timeshift,
		camera: camera,
		feed: feed,
		digits: digits,
		schedule: schedule,
		movement: movement,
		measure_is_open: measure_is_open,
		quantity: quantity,
		lockingStatus: lockingStatus
	};
	$.ajax({
		url: '/manager/reset',
		type: 'POST',
		data: data,
		success: function(response) {
				appClearer(app)
//			centreViewWriter(response);
		//	if ($('.now').attr('presence') != 'not') {

				if (type != 'start' && type != 'record' && navigation != 'resume') {
					navigation = 'once';
				}
				var diff = numeral(timestamp).value - numeral(now).value;
				diff = Math.abs(diff);
			//	if (diff < (1000 * 60)) {
					continent_record({'uuid':response['uuid'], 'app':response['app'],'purpose':'app','timestamp':response['timestamp'],'navigation':navigation});
			//	}
				calculator();
		//	}
		},
		error: function(error) { console.log(error) }
	});
}

function appClearer(app) {
	$('.appointment[app="' + app + '"]').each(function(i,v) {
		var container = $(v);
		localStorage.removeItem(app + '_notes');
		localStorage.removeItem(app + '_ago');
		localStorage.removeItem(app + '_duration');
		container.find('.ago').val('');
		container.find('.duration').val('');
		container.find('.schedule').val('');
		container.find('.text_editor').html('').trigger('change');
	});
}

function centreViewWriter(response) { 
	var res = $(response).find('.appointment');
	var app = $(res).attr('app');

	var appointments = $('body').find('.appointment');
	var matches = 0;
	if (appointments.length > 0) {
		$.each(appointments, function(n,val) {
			if ($(val).attr('app') == app) {
			//	$(val).replaceWith(response).show();
				matches = 1;
				windowMaker(response);
			}
		});
	}
	if (matches == 0) {
		windowMaker(response);
	}
	appointment_chron();
}


function appointmentGrabber(app,timestamp,source) {
	var waiter = 0;
	if (timestamp == '') {
		timestamp = Date.now();
	}
	if (source == 'onchange') {
		waiter = 500;
	}
	var jpR = jpReport(app);
	var appt = JSON.stringify({ app: app, name: app, source: 'grabber', jpReport: jpR });
	setTimeout(function() {
		$.ajax({ 
			url: '/manager/centre_view',
			type: 'GET',
			data: { app: appt, timestamp: timestamp, source: source },
			success: function(response) {
				centreViewWriter(response);
				jpRestore(app,jpR);
				var done = Date.now();
				console.log(app + ' ' + numeral(done - timestamp).value());
			}
		});
	},waiter);
}

var windows = [];
var top_level_now = 100;
var winLine = 0;
var fullXCount = 0;
var fullYCount = 0;


async function random_word(words) {
	var timestamp = Date.now();
	return await $.ajax({
		url: '/manager/random_word',
		type: 'GET',
		data: { 'times': words, 'timestamp': timestamp },
		success: function(response) {
			return response;

		}
	});
}

$(document).on('click', '.measures', function() {
	var a = $(this);
	var timestamp = Date.now();
	var parent = a.closest('.appointment');
	var app = parent.attr('app');
	var container = $('.appointment[app="' + app + '"]').find('.re_measures');
	if (container.is(':visible')) {
		container.hide();
	}
	else {
		appointmentMeasuresGrabber(a);
		container.show();
	}
});

$(document).on('touchmove mouseout hover keydown keyup touchend mousedown mouseup mousewheel', '.app_measure', function() {
	var mdm = $(this);
	var appt = mdm.closest('.appointment');
	var app = appt.attr('app');
	var value = mdm.val();
	var unit = mdm.attr('unit');
	var measure = mdm.attr('measure');
	appt.find('.app_measure_display[measure="' + measure + '"]').text(value + unit);


});

$(document).on('change keyup', '.app_measure', function() {
	var mdm = $(this);
	var appt = mdm.closest('.appointment');
	var app = appt.attr('app');
	var value = mdm.val();

	if (mdm.attr('multiple')) {
		value = JSON.stringify(value);
	}
	else if (mdm.attr('type') == 'checkbox') {
		if (mdm.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off';
		}
	}



	var measure = mdm.attr('measure');
	appt.find('.app_measure_display[measure="' + measure + '"]').text(value);
	mdm.attr('changed', 'yes');
	$.ajax({
		url: 'manager/app_measures',
		type: 'POST',
		data: { app: app, value: value, measure: measure, just_one: true, setting_only: 'yes', timestamp: timestamp },
		success: function(response) {
		}
	});
});


var amsave;
$(document).on('click', '.app_measure_save', function() {
	var mdm = $(this);
	var appt = mdm.closest('.appointment');
	var app = appt.attr('app');
	var container = mdm.closest('.appointment');
	var ago = $('#ago').val() || container.find('.ago').val();
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	appt.find('.app_measure[changed="yes"]').each(function(i,v) {

		var val = $(v).val();
		var measure = $(v).attr('measure');

		$.ajax({
			url: 'manager/app_measures',
			type: 'POST',
			data: { app: app, value: val, measure: measure, just_one: true, timestamp: timestamp, timeshift: timeshift, time_machine: time_machine, ago: ago },
			success: function(response) {
				$(v).attr('changed',undefined);
				mdm.addClass('superactive');
				clearTimeout(amsave);
				amsave = setTimeout(function() {
					mdm.removeClass('superactive');
				},1000);
				appClearer(app);
			}
		});
	});
});

$(document).on('click','.app_measure_delete', function() {
	var b = $(this);
	var app = b.closest('.appointment_detail').attr('app');
	var uuid = b.attr('uuid');
	var app_uuid = b.closest('.appointment_detail').attr('uuid');
	var armed = b.attr('armed');


	if (armed == 'yes') {
		b.addClass('superactive');
		$.ajax({
			url: '/manager/app_measure_delete',
			type: 'POST',
			data: { app: app, app_uuid: app_uuid, uuid: uuid },
			success:function(response) {

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

$(document).on('click','.edit_app',function() {

	var edit = $(this);
	var uuid = edit.attr('uuid');
	var app = edit.attr('app');
	var timestamp = edit.attr('timestamp');
	var appointment = edit.closest('.appointment');
	var ea = $('.appointment_edit_area[uuid="' + uuid + '"][app="' + app + '"]');
	if (ea.is(':visible')) {
		ea.hide();
	}
	else {
		$.ajax({
			url: '/manager/edit_app',
			type: 'GET',
			data: { app: app, uuid: uuid, timestamp: timestamp },
			success: function(response) {
				ea.html(response).show();
			}
		});

	}

});
$(document).on('click','.edit_app_submit', function() {
	var edit = $(this);
	var app = edit.attr('app');
	var uuid = edit.attr('uuid');
	var ea = $('.appointment_edit_area[uuid="' + uuid + '"]');
	var app_name = ea.find('[attribute="app"]').val();
	var timestamp = ea.find('[attribute="timestamp"]').attr('timestamp');
	var duration = ea.find('[attribute="duration"]').val();
	var warranty = ea.find('[attribute="warranty"]').attr('timestamp');
	var account = ea.find('[attribute="account"]').val();
	var project = ea.find('[attribute="project"]').val();
	var start_notes = ea.find('[attribute="start_notes"]').val();
	var notes = ea.find('[attribute="notes"]').val();
	var end_notes = ea.find('[attribute="end_notes"]').val();
	var movement = ea.find('[attribute="movement"]').val();
	var amount = ea.find('[attribute="amount"]').val();
	var tax = ea.find('[attribute="tax"]').val();
	var aux = ea.find('[attribute="aux"]').val();
	var total = ea.find('[attribute="total"]').val();
	var vendor = ea.find('[attribute="vendor"]').val();
	var unit = ea.find('[attribute="unit"]').val();
	var quantity = ea.find('[attribute="quantity"]').val();
	var has_tax = ea.find('.purchase_config[config="tax"]').attr('enabled');
	var has_totes = ea.find('.purchase_config[config="totes"]').attr('enabled');
	var item = ea.find('[attribute="item"]').val();
	var model = ea.find('[attribute="model"]').val();
	var state = ea.find('[attribute="state"]').val();
	$.ajax({
		url: '/manager/edit_app',
		type: 'POST',
		data: { 
			app: app,
			app_name: app_name,
			uuid: uuid, 
			timestamp: timestamp, 
			duration: duration, 
			warranty: warranty,
			account: account,
			project: project,
			start_notes: start_notes,
			notes: notes,
			end_notes: end_notes,
			movement: movement,
			amount: amount,
			tax: tax,
			aux: aux,
			total: total,
			vendor: vendor,
			unit: unit,
			quantity: quantity,
			item: item,
			model: model,
			has_tax: has_tax,
			has_totes: has_totes,
			state: state
		},
		success: function(response) {
			edit.removeClass('medium_thumb');
			edit.addClass('large_thumb');
			setTimeout(function() {
				edit.removeClass('large_thumb');
				edit.addClass('medium_thumb');
			}, 2000);
		},
	});
});

$(document).on('click', '.delete_app', function() {
	var a = $(this);
	var app = a.attr('app');
	var formatted_name = a.attr('formatted_name');
	var formatted_time = a.attr('formatted_time');
	var formatted_duration = a.attr('formatted_duration');
	var uuid = a.attr('uuid');
	var app_type = a.attr('app_type');
	var server_time = a.attr('server_time');
	var timestamp = a.attr('timestamp');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/delete_app',
			type: 'POST',
			data: { app: app, uuid: uuid, timestamp: timestamp, type: app_type, server_time: server_time },
			success: function(response) {
				$('.appointment_detail[uuid="' + uuid + '"]').remove();
				if (response.deleter.status == 'start' || response.deleter.status == 'record') {
					continent_cancel(app);
				}
			},
			error: function(err) { 
				$('#alert').html('It didn\'t work! Try again!<br><br><button id="alert_cancel">Cancel</button>');	
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

$(document).on('click', '.delete_file', function() {
	var a = $(this);
	var app_uuid = a.attr('app_uuid');
	var file_uuid = a.attr('file_uuid');
	var app = a.attr('app');
	if (a.attr('armed')) {
		$.ajax({
			url: '/manager/delete_file',
			type: 'POST',
			data: { app_uuid: app_uuid, file_uuid: file_uuid, app: app },
			success: function(response) {
				$.each(images, function(i,v) {
					if (v['app'] == response.app && response.file_uuid == v['uuid']) {
						images.splice(i,1);
						if (image_number == i && ($('#main_video').is(':visible') || $('#main_image').is(':visible'))) {
							galleryImageDisplayer();
						}
					}


				});
				$('[app_uuid="' + response.app_uuid + '"][file_uuid="' + response.file_uuid + '"]').remove();
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

$(document).on('change', '.file_information_updater', function() {
	var a = $(this);
	var value = a.val();
	var f = a.closest('.file_information');
	var attribute = a.attr('attribute');
	var file_uuid = f.attr('file_uuid');
	var app_uuid = f.attr('app_uuid');
	var app = f.attr('app');
	var data = { app: app, file_uuid: file_uuid, app_uuid: app_uuid, attribute: attribute, value: value };
	$.ajax({
		url: '/manager/file/information_updater',
		type: 'POST',
		data: data,
		success: function(response) {
			a.val(response['value']);
		}
	});
});


$(document).on('click', '.close_appointment', function() {
	var t = $(this);
	var p = t.closest('.appointment');
	var w = p.closest('.window_view');
	p.closest('.wind').remove();
	var height = $(window).height(); 
	if (p.find('#mouse_shadow')) { $('#mouse_shadow').css({ 'top': height }); }
	var containers = p.find('.appointment');
	if (containers.length == 1) {
		p.hide();
	}
	var app = t.attr('app');
	websocketStop(app);

	windowSaver();
	$('#' + app).remove();
	$('#' + app).closest('.wind').remove();
	if (w.find('.appointment :visible').length == 0) {
		w.hide();
	}
});

function appointmentMeasuresGrabber(a) {
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	var container = parent.find('.re_measures');
	$.ajax({
		url: '/manager/appointment_measures',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			container.html(response).show();
		}
	});
}


$(document).on('click', '.det', function() {

	var a = $(this);
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	var container = parent.find('.re_details');
	if (container.is(':visible')) {
		container.html('<span class="detail_json" app="' + app + '">{}</span>').hide();
	}
	else {
		appointmentDetailsGrabber(a);
		container.show();
	}
});

$(document).on('click', '.register', function() {
	var a = $(this);
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	var container = parent.find('.re_register');
	if (container.is(':visible')) {
		container.html('').hide();
	}
	else {
		registerGrabber(app);
		container.show();
	}
});

function registerGrabber(app) {
	var container = $('.appointment[app="' + app + '"]').find('.re_register');
	$.ajax({
		url: '/manager/register_grabber',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			container.html(response.html);
			openAttributeReopener(app)
		}
	});
}


var appDetailsScroll = {};

$(document).on('mousewheel touchmove', '.detail_area', function(e) {
	if ($(e.target).is('canvas')) {
		e.preventDefault();e.preventDefault();
	}
	var app = $(this).attr('app');
	var scroll = $(this).offset().top;
	var height = $(this).height();
	var cheight = $(this).closest('.appointment').height();
	if ((height - (cheight + Math.abs(scroll))) < 530) {
		if (appDetailsScroll[app]['reload'] == 0) {
			appDetailsScroll[app]['reload'] = 1;
			
		//	appointmentDetailsGrabber($(this),'scroll');
		}
	}
});

function appointmentDetailsGrabber(a,source) {
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	if ($('.wind[app="' + app + '"]').length > 0) {
		var container = parent.find('.re_details');
		container.html('');
		var timestamp = Date.now();
		var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
		var time_machine = localStorage.getItem('time_machine');
		var sorts = localStorage.getItem('sorts');
		var scope = localStorage.getItem('scope');
		var filter = localStorage.getItem('filter');

		if (source == 'scroll') {

		}

		var variables = { sorts: sorts, app: app, filter: filter, time_machine: time_machine, timeshift: timeshift, timestamp: timestamp, scope: scope };
		$.ajax({ 
			url: '/manager/appointment_details',
			type: 'GET',
			data: variables,
			success: function(response) {
				container.html(response);
				container.show();
				appointment_chron();
				appDetailsScroll[app]['reload'] = 0;
			}
		});
	}
}

function appointmentDetailGrabber(app,uuid) {
	if ($('.wind[app="' + app + '"]').length > 0) {
		var timestamp = Date.now();
		var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
		var time_machine = localStorage.getItem('time_machine');
		var sorts = localStorage.getItem('sorts');
		var scope = localStorage.getItem('scope');
		var filter = localStorage.getItem('filter');
		var variables = { uuid: uuid, sorts: sorts, app: app, filter: filter, time_machine: time_machine, timeshift: timeshift, timestamp: timestamp, scope: scope };
		var lists = []
		$('.appointment_detail[uuid="' + uuid + '"]').find('.appointment_list').each(function(i,v) {
			if ($(v).is(':visible')) {
				lists.push($(v).attr('list'));
			}
		});
		$.ajax({
			url: '/manager/appointment_details',
			type: 'GET',
			data: variables,
			success: function(response) {
				var selector = '.appointment_detail[uuid="' + uuid + '"][app=\"' + app + '\"]';
				if ($(selector).length > 0) {
					$(selector).html($(response).find(selector).html());
				}
				else {
					$('.detail_area[app="' + app + '"]').append($(response).find(selector).clone());
				}
				appointment_chron();
				var q = $('.appointment_detail[app="' + app + '"]').length;
				$('.detail_quantity[app="' + app + '"]').text(q);
				$.each(lists, function(i,v) {
					$('.appointment_detail[uuid="' + uuid + '"]').find('.appointment_list[list="' + v + '"]').show();
				});
			}
		});
	}
}

function appointmentDetailsUpdater(app) {

	var updates = {};
	var selector1 = '.detail_area';
	if (app) {
		selector1 = '.detail_area[app="' + app + '"]';
	}
	$(selector1).each(function(n,ve) {
		var dapp = $(ve).attr('app');
		if ($('.wind[app="' + dapp + '"]').length > 0) {
			updates[dapp] = {};
			updates[dapp]['details'] = [];
			var data = $('.detail_json[app="' + dapp + '"]').text() || {};
			updates[dapp]['data'] = JSON.parse(data);
			$.ajax({
				url: '/manager/appointment_details',
				type: 'GET',
				data: updates[dapp]['data'],
				success: function(response) {
					var results = $(response).find('.appointment_detail[app="' + dapp + '"]');

					results.each(function(i,v) {
						var uuid = $(v).attr('uuid');
						var last_update = $(v).attr('last_update');
						var selector = '.appointment_detail[app="' + dapp + '"][uuid="' + uuid + '"]';
						var vn = $(selector);
						if (vn.length > 0 && vn.is(':visible')) {
							if ($(v).attr('last_update') > vn.attr('last_update')) {
								vn.replaceWith($(v).clone());
							}
						}
						else {
							$('.detail_area[app="' + dapp + '"]').append($(v).clone());
						}
						var q = results.length;
						$('.detail_quantity[app="' + dapp + '"]').text(q);
					});
				}	
			});
		}
	});
}

$(document).on('click', '.notespace', function() {
	var text = $(this).html();
	text = text.replaceAll('<br>', "\n");
	
	var notes = $(this).closest('.appointment').find('.notes');

	notes.val(text);


});

$(document).on('click', '.notes_toggle', function() {
	var toggle = $(this);
	var timestamp = Date.now();
	var app = toggle.attr('app');
	var app_timestamp = toggle.attr('timestamp');
	var server_time = toggle.attr('server_time');
	var uuid = toggle.attr('uuid');
	var appointment = toggle.closest('.appointment_detail');
	var notespace = appointment.find('.notespace');
	if (notespace.html() == '') {
		$.ajax({
			url: '/manager/note_retriever',
			type: 'GET',
			data: { app_timestamp: app_timestamp, timestamp: timestamp, app: app, server_time: server_time, uuid: uuid },
			success: function(response) {
				notespace.html(response.notes).show();
			}
		});
	}
	else {
		notespace.html('');
		notespace.hide();
	}
});


$(document).on('click', '.leave', function() {
	leave();
});
function leave() {
	var d = JSON.stringify(localStorage);
	jpStop();
	websocketStop();
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/leave',
		type: 'POST',
		data: { timestamp: timestamp, debriefer: d },
		success: function(response) {
			localStorage.clear();
//			$('body').replaceWith(response);
			location.reload();
		},
		error: function(err) { console.log('Error', err); }
	});
}

$(document).on('click', '#lock_session', function() {
	$.ajax({
		url: '/manager/lock_session',
		type: 'POST',
		data: { },
		success: function() {

		}

	});
});

$(document).on('click', '#alert_cancel', function() {
	$('#alert_message').text('');
	$('#alert').html('');
	$('#alert').hide();
	$('#alert').attr('hidden', 'yes');
});

$(document).on('click','.enabler', function() {
	var strawbeery = $(this);
	var appointment = strawbeery.closest('.appointment');
	var app = appointment.attr('app');
	var timestamp = Date.now();
	var setting = strawbeery.attr('type') || 'notification';
	var status = strawbeery.attr('status');
	var on_colour = strawbeery.attr('on_colour');
	var off_colour = strawbeery.attr('off_colour');
	var dim = strawbeery.attr('dim');
	if (status == 'on') {
		strawbeery.css({ 'background-color': off_colour });
		if (dim) { strawbeery.css({ 'border-color': off_colour, 'opacity': '0.45', 'filter': 'grayscale(1)', 'box-shadow': 'none' }); }
		status = 'off';
	}
	else {
		strawbeery.css({ 'background-color': on_colour });
		if (dim) { strawbeery.css({ 'border-color': on_colour, 'opacity': '1', 'filter': 'none', 'box-shadow': '0 0 8px 2px ' + on_colour }); }
		status = 'on';
	}

	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: app, timestamp: timestamp, setting: setting, value: status, source: 'panel' },
		success: function(response) {
			centreViewWriter(response)
		}
	});
});

$(document).on('click','.remote_manager',function() {
	var m = $(this);
	var ip = m.attr('id');
	var mac = m.attr('mac');
	var manager = m.attr('manager');
	var timestamp = Date.now();

	if (manager) {
			$('<iframe>', {
				src: manager,
				id:  'browser_' + timestamp,
				frameborder: 0,
				scrolling: 'yes',
				style: "position:fixed;bottom:0;width:40%;height:40%"
			}).appendTo('#remote_managers');
	}
});

function cacheSet(params,data) {
	var jdata = JSON.stringify(data);
	$.ajax({
		url: '/manager/cache_set',
		type: 'POST',
		data: {
			app: params['app'],
			context: params['context'],
			subcontext: params['subcontext'],
			timestamp: params['timestamp'],
			data: jdata
		},
		success: function(response) {}
	});
}

async function cacheGet(params) {

	return $.ajax({
		url: '/manager/cache_get',
		type: 'GET',
		data: {
			app: params['app'],
			context: params['context'],
			subcontext: params['subcontext'],
			timestamp: params['timestamp'],
		},
		success: function(response) {
		}
	});
}

function cacheDelete(params) {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/cache_delete',
		type: 'POST',
		data: {
			app: params['app'],
			context: params['context'],
			subcontext: params['subcontext'],
			timestamp: timestamp,
		},
		success: function(response) {}
	});
}
