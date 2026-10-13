// Shared marker plumbing for the pan-able maps (Travel and the continent
// background). jawnosMap draws the markers and reports a tap; these helpers turn
// a list of places into markers grouped by their spot, unfold a grouped marker
// into a list, and open the app's appointment window when one is picked.
//
// A marker the engine can hit is { lat, lon, app, count?, list?, label, colour }:
// `app` is the single app it stands for; a group instead carries `list` (with a
// `count` > 1) and wears the count in its disc.

// The ground distance between two { lat, lon } markers, in metres - the
// equirectangular approximation is plenty at the scale one spot is judged at.
function jawnosMarkerMetres(a, b) {
	var mid = (a.lat + b.lat) / 2 * Math.PI / 180;
	var dLat = (a.lat - b.lat) * 111194.9;
	var dLon = (a.lon - b.lon) * 111194.9 * Math.cos(mid);
	return Math.sqrt((dLat * dLat) + (dLon * dLon));
}

// Group co-located markers: within `metres` of a group's centre a marker joins it
// (the centre drifts to the average of its members). Each member is { app, name,
// lat, lon, colour }; a group carries the members and no label of its own - the
// count is drawn in the disc and the names unfold on a tap.
function jawnosMarkerGroups(markers, metres, fallback) {
	var clusters = [];
	$.each(markers || [], function(i, v) {
		var lat = parseFloat(v['lat']);
		var lon = parseFloat(v['lon']);
		if (!isFinite(lat) || !isFinite(lon)) { return; }
		var marker = { app: v['app'], name: v['name'] || v['app'], colour: v['colour'] || fallback, lat: lat, lon: lon };
		for (var c = 0; c < clusters.length; c++) {
			var cluster = clusters[c];
			if (jawnosMarkerMetres(cluster, marker) <= metres) {
				var n = cluster.list.length;
				cluster.lat = ((cluster.lat * n) + lat) / (n + 1);
				cluster.lon = ((cluster.lon * n) + lon) / (n + 1);
				cluster.list.push(marker);
				return;
			}
		}
		clusters.push({ lat: lat, lon: lon, list: [marker] });
	});
	var out = [];
	$.each(clusters, function(i, cluster) {
		if (cluster.list.length == 1) {
			out.push({ lat: cluster.lat, lon: cluster.lon, app: cluster.list[0].app, label: cluster.list[0].name, colour: cluster.list[0].colour, list: cluster.list });
		}
		else {
			out.push({ lat: cluster.lat, lon: cluster.lon, app: '', count: cluster.list.length, list: cluster.list, colour: cluster.list[0].colour || fallback });
		}
	});
	return out;
}

// A tap on a marker: one that stands for a single app opens that app's
// appointment window; a grouped one unfolds the list of its apps beside it.
function jawnosMarkerTapped(marker, sx, sy, canvas) {
	if (marker.list && marker.list.length > 1) {
		jawnosMarkerList(marker, sx, sy, canvas);
		return;
	}
	var app = marker.app || (marker.list && marker.list.length ? marker.list[0].app : '');
	if (app) { appointmentGrabber(app, Date.now()); }
}

// The little list a grouped marker unfolds: every place in it by name, a click on
// a name opening that app's appointment window.
function jawnosMarkerList(marker, sx, sy, canvas) {
	jawnosMarkerListHide();
	if (!canvas) { return; }
	var rect = canvas.getBoundingClientRect();
	var list = $('<div id="jawnos_marker_list"></div>').css({
		position: 'fixed',
		left: Math.max(4, Math.min(rect.left + sx + 12, $(window).width() - 190)) + 'px',
		top: Math.max(4, Math.min(rect.top + sy + 12, $(window).height() - 190)) + 'px',
		'z-index': 9000,
		'background-color': 'var(--panel)',
		border: '2px solid var(--line)',
		'border-radius': '8px',
		padding: '4px 8px',
		'max-height': '34vh',
		'overflow-y': 'auto',
		'box-shadow': '0 6px 18px rgba(0,0,0,.35)',
		'font-size': '13px',
		'min-width': '130px'
	});
	$('<b></b>').text(marker.list.length + ' apps').appendTo(list);
	$.each(marker.list, function(i, item) {
		$('<span class="jawnos_marker_item"></span>')
			.attr('app', item.app)
			.css({ display: 'block', padding: '3px 4px', cursor: 'pointer' })
			.text(item.name || item.app)
			.appendTo(list);
	});
	list.appendTo('body');
}

function jawnosMarkerListHide() {
	$('#jawnos_marker_list').remove();
}
$(document).on('click', '.jawnos_marker_item', function() {
	var app = $(this).attr('app');
	jawnosMarkerListHide();
	if (app) { appointmentGrabber(app, Date.now()); }
});
$(document).on('mousedown touchstart', function(e) {
	if ($(e.target).closest('#jawnos_marker_list').length == 0) { jawnosMarkerListHide(); }
});
