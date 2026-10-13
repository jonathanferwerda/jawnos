var campusProxy = {};
var locationWatchers = {};
var mapData = {};
$(document).on('click', '#travel_toggle', function() {
	travelToggle();
});

function travelToggle() {
	var ts = Date.now();
	if ($('.now').attr('presence') == 'not') {
		ts = timestamp; 
	}
	var url = '/manager/travel';
	var travel_scope = localStorage.getItem('travel_scope');
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: ts },
		success: function(response) {
			windowMaker(response);

			travelViewer({ timestamp: ts });
			//continent_record({'app':'travel','timestamp':ts,'purpose':'travel_viewer','scope':travel_scope});
		}, error: function (response) {  }
	});
}


// The travel map is drawn by jawnosMap (public/js/manager/mapengine.js): a pan-able
// viewport that shows every measured map we have, each placed by the georeference it
// carries (its home_plate pixel and scale bar), over an optional tile layer from a
// chosen provider, with the continent points and the machine's current position on
// top. Drag to pan; wheel or pinch to zoom.
var travelMap;
var travelFramed = false;

function travelMapEngine() {
	var canvas = document.getElementById('travel_campus');
	if (!canvas || !window.jawnosMap) { return null; }
	if (travelMap && travelMap.canvas === canvas) { return travelMap; }
	// a fresh canvas (the window was reopened) needs a fresh engine
	travelMap = window.jawnosMap.create('travel_campus', {
		z: 16,
		width: function() { return $('#travel_campus').parent().width() || 640; },
		height: function() { return Math.max(240, Math.round($(window).height() * 0.6)); }
	});
	travelFramed = false;
	return travelMap;
}

// Fill the provider picker from the engine's own table, so the two cannot drift.
function travelProviderFill() {
	var sel = $('.travel_provider');
	if (!sel.length || sel.attr('filled') == 'yes' || !window.jawnosMap) { return; }
	sel.attr('filled', 'yes');
	var engines = window.jawnosMap.providers;
	for (var key in engines) {
		$('<option></option>').attr('value', key).text(engines[key].name).appendTo(sel);
	}
	sel.val(sel.attr('provider') || 'none');
}

function travelMapRender(response) {
	if (!window.jawnosMap) { return; }
	travelProviderFill();
	var engine = travelMapEngine();
	if (!engine) { return; }
	engine.setProvider($('.travel_provider').val() || 'none', $('#travel_custom_url').val());
	engine.setMaps(response['all_maps'] || []);

	var points = [];
	$.each(response['near'] || [], function(i, point) {
		if (!point || !point['latitude'] || !point['longitude']) { return; }
		if (point['settings'] && point['settings']['visible'] && point['settings']['visible'] != 'checked') { return; }
		points.push({
			lat: parseFloat(point['latitude']),
			lon: parseFloat(point['longitude']),
			label: point['app'] || '',
			colour: (point['settings'] && point['settings']['colour']) || undefined
		});
	});
	engine.setPoints(points);

	var pos = response['position'];
	var hasPos = pos && pos['latitude'];
	engine.setPosition(hasPos ? { lat: parseFloat(pos['latitude']), lon: parseFloat(pos['longitude']), label: pos['label'] || 'You are here' } : null);

	// frame the current position (with the maps around it) the first time; after
	// that leave the view where the user panned it
	if (!travelFramed) {
		if (hasPos) { engine.focusOn(parseFloat(pos['latitude']), parseFloat(pos['longitude'])); }
		else if ((response['all_maps'] || []).length) { engine.fitToMaps(); }
		travelFramed = true;
	}
	engine.draw();
}

function travelViewer(data) {
	if (!data) { data = {}; }
	var ts = Date.now();
	if ($('.now').attr('presence') == 'not') {
		ts = data['timestamp']; 
	}
	var jsettings;
	if (data['settings']) {
		jsettings = JSON.stringify(data['settings']);
		console.log(data['settings']);
		console.log(jsettings);
	}
	var travel_scope = $('#travel_scope').val();
	var time_scope = localStorage.getItem('scope');
	var sel = $('.travel_map_selector').find('option[selected]');
	var map = sel.val();
	var tdata = { map: map, travel_scope: travel_scope, uuid: data['uuid'], time_scope: time_scope, timestamp: ts, settings: jsettings };
	console.log(tdata);
	$.ajax({
		url: '/manager/travel/viewer',
		type: 'GET',
		data: tdata,
		success: function(response) {
			console.log(response);
			mapData = response;
			$('#travel_campus').show();
			$('#travel_proxy_view').html(response['html']);
			travelMapRender(response);
			$('#travel_start_time').attr('timestamp', response['start_time']);
			$('#travel_end_time').attr('timestamp', response['end_time']);
			$('#travel_appt').val(response['settings']['search']);
			appointment_chron();
		}
	});
}

$(document).on('click', '#travel_update', function() {
	var ts = Date.now();
	if ($('.now').attr('presence') == 'not') {
		ts = timestamp; 
	}

	var travel_scope = localStorage.getItem('travel_scope');
	if ($('#travel_home_plate').attr('status') == 'disabled') {
	//	continent_record({'app':'travel','timestamp':ts,'purpose':'travel_viewer','scope':travel_scope,'navigation':'once'});
		travelViewer({ timestamp: ts });
	}
	else {
		travelViewer({ timestamp: ts });
	}
});

$(document).on('change', '#travel_scope', function() {
	var scope = $(this).val();
	localStorage.setItem('travel_scope', scope);
	settingSetter({ 'app': 'travel', 'setting': 'travel_scope' });
});

$(document).on('click', '#travel_home_plate', function() {
	var t = $(this);
	var status = 'enabled';
	if (t.attr('status') == 'enabled') {
		status = 'disabled';
	}
	else {
		status = 'enabled';
	}
	t.attr('status',status);
	settingSetter({ 'app': 'travel', 'setting': 'home_plate_enabled', 'value': t.attr('status') });
	travelViewer({ settings: { 'home_plate_enabled': t.attr('status') } });
});


function continent_cancel(app) {
	if (eval(navigator.geolocation) && locationWatchers[app]) {
		navigator.geolocation.clearWatch(locationWatchers[app]['watch']);
//		locationWatchers[app]['watch'] = null;
	}
}

function continent_record(setter) {
	var navigation = setter['navigation'];
	if (navigation == 'none') {
		return;
	}
	var app = setter['app'] || 'me';
	var timestamp = setter['timestamp'];
	var purpose = setter['purpose'];
	var scope = setter['scope'];
	var device = setter['device'];
	timestamp = timestamp || Date.now();
	var hostname = $(location)[0]['hostname'];
	var pathname = $(location)[0]['pathname'];
	var protocol = $(location)[0]['protocol'];
	var uuid = setter['uuid'];

	if (!navigation) {
	//	navigation = $('.appointment[app="' + app + '"]').attr('navigation');
	}
	var now = Date.now();
	if (!locationWatchers[app]) {
		locationWatchers[app] = { watch: undefined, timer: (now - numeral(navigation).value()) };
	}
	else {
		navigator.geolocation.clearWatch(locationWatchers[app]['watch']);
	}
	var returner;
	var gotLocation = 0;
	
	if (navigator.geolocation) { 
		if (navigation == 'once' || navigation == undefined || navigation == 0) {
			navigator.geolocation.getCurrentPosition((position) => {
				gotLocation = 1;
				var data = position.coords;
				now = Date.now();
				if (now - position.timestamp < 2000) {
					$.ajax({
						url: '/manager/continent/record',
						type: 'POST',
						data: { 
							latitude: data.latitude,
							longitude: data.longitude,
							altitude: data.altitude,
							speed: data.speed,
							accuracy: data.accuracy,
							timestamp: position.timestamp,
							user_agent: navigator.userAgent,
							hostname: hostname,
							pathname: pathname,
							protocol: protocol,
							purpose: purpose,
							scope: scope,
							app: app,
							device: device,
							uuid: uuid,
							navigation: setter['navigation']
						},
						success: function(response) {
							return response;
						},
					});
				}
				else {
					continent_record_anyway({ app: app, scope:scope, uuid:uuid, purpose:purpose, timestamp: timestamp, device: device });
				}
			}, (error) => {
				continent_record_anyway({ app: app, uuid:uuid, scope:scope, purpose:purpose, timestamp: timestamp, device: device });
			}, { 
				maximumAge:1_000, enableHighAccuracy: true 
			});
		}
		else {

			locationWatchers[app]['watch'] = navigator.geolocation.watchPosition((position) => {
				gotLocation = 1;
				var data = position.coords;

				var now = Date.now();
				if (now > locationWatchers[app]['timer']) {
					locationWatchers[app]['timer'] = (now + numeral(navigation).value());
					if (now - position.timestamp < 2000) {
						$.ajax({
							url: '/manager/continent/record',
							type: 'POST',
							data: { 
								latitude: data.latitude,
								longitude: data.longitude,
								altitude: data.altitude,
								speed: data.speed,
								accuracy: data.accuracy,
								timestamp: position.timestamp,
								user_agent: navigator.userAgent,
								hostname: hostname,
								pathname: pathname,
								protocol: protocol,
								purpose: purpose,
								scope: scope,
								app: app,
								device: device,
								uuid: uuid,
								navigation: setter['navigation'],
								next_navigation: locationWatchers[app]['timer']
							},
							success: function(response) {

								return response;
							},
						});
					}
				}
				else {
					continent_record_anyway({ app: app, scope:scope, uuid:uuid, purpose:purpose, timestamp: timestamp, device: device });
				}
			}, (error) => {
				continent_record_anyway({ app: app, scope:scope, uuid:uuid, purpose:purpose, timestamp: timestamp, device: device });
			}, { 
				maximumAge:1_000, enableHighAccuracy: true 
			});
		}
	} 
}

function continent_record_anyway(data) {
	$.ajax({
		url: '/manager/continent/record_anyway',
		type: 'POST',
		data: data,
		success: function(response) {

		}
	}); 
}

$(document).on('click', '.delete_location', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var server_time = a.attr('server_time');
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/continent/delete',
			type: 'POST',
			data: { uuid: uuid, server_time: server_time },
			success:function(response) {

				$('.appointment_distance_container[uuid="' + response.uuid + '"]').remove();
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

$(document).on('change', '.travel_map_selector', function() {
	var uuid = $(this).val();
	settingSetter({ 'app': 'travel', 'setting': 'current_map', 'value': uuid });

	var s = $('.travel_map_selector').find('option[selected]').removeAttr('selected');

	$('.travel_map_selector').find('option[value="' + uuid + '"]').attr('selected', 'yes');
	
	setTimeout(function() {
		var timestamp = Date.now();
		travelViewer({ timestamp: timestamp });
	},200);
});


$(document).on('click', '.delete_travel_map', function() {
	var a = $(this);
	var sel = $('.travel_map_selector').find('option[selected]');
	var uuid = sel.attr('value');
	var app_uuid = sel.attr('app_uuid');
	var app = sel.attr('app');
	if (a.attr('armed') == 'yes') {
		var obg = a.attr('obg');
		a.css({'background-color': obg });

		$.ajax({
			url: '/manager/travel/delete_map',
			type: 'POST',
			data: { file_uuid: uuid, app_uuid: app_uuid, app: app },
			success: function(response) {
				travelToggle();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.attr('obg', bgcolor);
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');
		},2000);
	}
});

$(document).on('change', '.travel_provider', function() {
	var value = $(this).val();
	settingSetter({ 'app': 'travel', 'setting': 'map_provider', 'value': value });
	if (travelMap) { travelMap.setProvider(value, $('#travel_custom_url').val()); }
});

$(document).on('change', '#travel_custom_url', function() {
	var value = $(this).val();
	settingSetter({ 'app': 'travel', 'setting': 'map_custom_url', 'value': value });
	if (travelMap) { travelMap.setProvider($('.travel_provider').val() || 'none', value); }
});

$(document).on('click', '#travel_config_toggle', function() {

	var tc = $('#travel_config');
	var status = tc.attr('status');
	if (status == 'visible') {
		status = 'hidden';
		tc.hide();
	} else {
		status = 'visible';
		// the toolbar is a flex row; .show() would restore the default block display
		tc.css('display', 'flex');
	}
	tc.attr('status', status);
	settingSetter({ 'app': 'travel', 'setting': 'config_visible', 'value': status });
});

$(document).on('click', '.travel_now', function() {
	settingDeleter({ 'app': 'travel', 'setting': 'start_time' });
	settingDeleter({ 'app': 'travel', 'setting': 'end_time' });
	settingDeleter({ 'app': 'travel', 'setting': 'appt' });
	var settings = {
		start_time: null,
		end_time: null,
		appt: null
	};
	var timestamp = Date.now();
	travelViewer({ timestamp: timestamp, settings: settings });
});

$(document).on('change', '#travel_search', function() {
	var search = $(this).val();
	settingSetter({'app':'travel','setting':'search', 'value': search });
});

$(document).on('click', '.site_type_manual_changer_toggle', function() {
	if ($('.start_menu_main_display').is(':visible') && $('.site_type_manual_changer_options').length > 0) {
		console.log('showing');
		$('.start_menu_main_display').hide();
		$('.site_type_manual_changer_options').show();
	}
	else {
		console.log('hiding');
		$('.start_menu_main_display').show();
		$('.site_type_manual_changer_options').hide();
	}
});

$(document).on('click', '.site_type_manual_changer', function() {
	var site = $(this).attr('site');
	console.log(site);
	$.ajax({
		url: '/manager/configure/site_type/manual_change',
		type: 'POST',
		data: {
			site: site
		},
		success: function(response) {
			console.log(response);
			startMenuToggle({ source: 'updated' });
		}
	});
});