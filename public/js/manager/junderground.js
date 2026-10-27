// The Chat app's Rooms section: dial a junderground, see the door and the
// roster, grade it against the house's own people list, and join or leave.
// The switch URL and the house handle are the only settings; signing happens
// on the server, so the crest key never reaches this file.
(function () {
	function jgT(text) { return (typeof jawnosT === 'function') ? jawnosT(text) : text; }
	function jgEsc(value) { return $('<div>').text(value == null ? '' : String(value)).html(); }
	function jgTime(ts) { return ts ? new Date(ts * 1000).toLocaleString() : ''; }

	var jgPresence = {};
	var jgSockets = {};

	// The signaling socket goes straight to the switch (the browser cannot ask
	// the Perl side to hold a WebSocket). The grant is short-lived and rides
	// the query string because a WebSocket handshake cannot carry a header.
	function jgWsBase() {
		var url = $.trim($('#jg_url').val() || '');
		if (!/^https?:\/\//i.test(url)) { return ''; }
		return url.replace(/\/+$/, '').replace(/^http/i, 'ws');
	}

	function jgSocketClose(handle, room) {
		var key = handle + '/' + room;
		var ws = jgSockets[key];
		delete jgSockets[key];
		if (!ws) { return; }
		try { ws.close(); } catch (e) {}
	}

	function jgSocketOpen(handle, room, grant) {
		jgSocketClose(handle, room);
		var base = jgWsBase();
		if (!base || !grant) { return; }
		var key = handle + '/' + room;
		var ws;
		try {
			ws = new WebSocket(base + '/v1/rooms/' + encodeURIComponent(handle) + '/' +
				encodeURIComponent(room) + '/ws?grant=' + encodeURIComponent(grant));
		} catch (e) {
			$('#jg_status').text(jgT('The signaling channel did not open.'));
			return;
		}
		jgSockets[key] = ws;
		ws.onopen = function () { $('#jg_status').text(jgT('Signal open')); };
		ws.onmessage = function (event) {
			var msg;
			try { msg = JSON.parse(event.data); } catch (e) { return; }
			if (!msg || !msg.type) { return; }
			if (msg.type === 'hello') {
				$('#jg_status').text(jgT('Live') + ' · ' + (msg.peers || 1) + ' ' + jgT('in the room'));
			} else if (msg.type === 'error') {
				$('#jg_status').text(msg.error || '');
			} else if (msg.type === 'join' || msg.type === 'leave') {
				jgOpen(handle, room);
			}
		};
		ws.onerror = function () { $('#jg_status').text(jgT('The signaling channel did not open.')); };
		ws.onclose = function () {
			if (jgSockets[key] === ws) { delete jgSockets[key]; }
		};
	}

	function jgConfigLoad() {
		if (!$('#jg_panel').length) { return; }
		$.getJSON('/manager/junderground/config', function (r) {
			$('#jg_url').val(r.url || '');
			$('#jg_handle').val(r.handle || '');
			$('#jg_known').val(r.known || '');
			$('#jg_blacklist').val(r.blacklist || '');
			$('#jg_hostile').val(r.hostile || '');
		});
	}

	function jgConfigWhenReady(attempts) {
		if ($('#jg_panel').length) { jgConfigLoad(); return; }
		if (attempts > 0) { setTimeout(function () { jgConfigWhenReady(attempts - 1); }, 200); }
	}

	function jgPicks() {
		var picks = {};
		$('#jg_panel .jg_pick').each(function () {
			var value = $.trim($(this).val());
			if (value) { picks[$(this).attr('kind')] = value; }
		});
		return picks;
	}

	function jgScope(constructs) {
		if (!constructs) { return ''; }
		return Object.keys(constructs).sort().map(function (key) {
			return key + '=' + constructs[key];
		}).join(' · ');
	}

	function jgPost(path, payload, done) {
		$.ajax({
			url: path, type: 'POST', dataType: 'json',
			data: { incoming_data: JSON.stringify(payload || {}) }
			}).done(done).fail(function () {
				$('#jg_status').text(jgT('Could not reach the switch.'));
				$('#jg_canonical').text('');
			});
	}

	function jgDial() {
		$('#jg_status').text(jgT('Dialling…'));
		$('#jg_canonical').text('');
		jgPost('/manager/junderground/dial', { picks: jgPicks() }, function (r) {
			$('#jg_status').text(r.error || '');
			var canonical = r.error ? '' : jgScope(r.dial);
			$('#jg_canonical').text(canonical);
			var box = $('#jg_rooms').empty();
			var rooms = r.rooms || [];
			if (!rooms.length) {
				$('<div class="jg_empty">').text(jgT('No room on that dial.')).appendTo(box);
				return;
			}
			rooms.forEach(function (room) {
				var card = $('<div class="jg_room">').attr({ handle: room.handle, room: room.room });
				$('<div class="jg_room_name">').text(room.name || room.room).appendTo(card);
				$('<div class="jg_scope">').text(jgScope(room.constructs)).appendTo(card);
				if (room.advertised) { $('<span class="jg_badge">').text(jgT('Advertised')).appendTo(card); }
				box.append(card);
			});
		});
	}

	function jgOpen(handle, room) {
		jgPost('/manager/junderground/room', { handle: handle, room: room }, function (data) {
			jgRenderDetail(handle, room, data);
		});
	}

	function jgRenderDetail(handle, room, data) {
		var box = $('#jg_detail').empty();
		var meta = data.room || {};
		var door = data.door || {};
		var grade = data.grade || {};
		var rentals = (data.rentals && data.rentals.rentals) || [];
		var roster = (data.presence && data.presence.roster) || [];
		var key = handle + '/' + room;

		$('<div class="jg_detail_head">')
			.append($('<b>').text(meta.name || room))
			.append($('<span class="jg_scope">').text(key))
			.appendTo(box);

		$('<div class="jg_scope">').text(jgScope(meta.constructs)).appendTo(box);

		var doorBox = $('<div class="jg_door">').attr('data-state', door.state || 'open')
			.text(jgT('Door') + ': ' + jgT(door.state || 'open')).appendTo(box);
		if (door.notify_at) {
			$('<div class="jg_scope">').text(jgT('Reserved') + ' ' + jgTime(door.start) +
				' · ' + jgT('notice') + ' ' + jgTime(door.notify_at)).appendTo(doorBox);
		}

		if (rentals.length) {
			var rentalBox = $('<div class="jg_rentals">').appendTo(box);
			$('<div class="jg_scope">').text(jgT('Rentals')).appendTo(rentalBox);
			rentals.forEach(function (rental) {
				$('<div class="jg_rental">').text(
					(rental.label || rental.event || jgT('Reserved')) + ' · ' +
					jgTime(rental.start) + '–' + jgTime(rental.end) +
					(rental.guest_start ? ' · ' + jgT('guests') + ' ' + jgTime(rental.guest_start) + '–' + jgTime(rental.guest_end) : '')
				).appendTo(rentalBox);
			});
		}

		var gradeBox = $('<div class="jg_row">').appendTo(box);
		$('<span class="jg_grade">').attr('data-grade', grade.grade || 'empty')
			.text(jgT(grade.grade || 'empty')).appendTo(gradeBox);
		if (grade.block) { $('<span class="jg_block">').text(jgT('Blacklisted person in this room')).appendTo(gradeBox); }

		if (roster.length) {
			var rosterBox = $('<div class="jg_roster">').appendTo(box);
			roster.forEach(function (entry) {
				$('<div>').text(entry.subject + (entry.ticketed ? ' · ' + jgT('pass') : '')).appendTo(rosterBox);
			});
		}

		var actions = $('<div class="jg_row">').appendTo(box);
		$('<button type="button" id="jg_join">').attr({ handle: handle, room: room })
			.text(jgT('Join')).appendTo(actions);
		if (jgPresence[key]) {
			$('<button type="button" id="jg_leave">').attr({ handle: handle, room: room })
				.text(jgT('Leave')).appendTo(actions);
		}
	}

	$(document).on('click', '#jg_save', function () {
		jgPost('/manager/junderground/config', {
			url: $('#jg_url').val(), handle: $('#jg_handle').val(),
			known: $('#jg_known').val(), blacklist: $('#jg_blacklist').val(), hostile: $('#jg_hostile').val()
		}, function (r) {
			$('#jg_status').text(r.ok ? jgT('Saved') : (r.error || ''));
		});
	});

	$(document).on('click', '#jg_register', function () {
		$('#jg_status').text(jgT('Registering…'));
		jgPost('/manager/junderground/register', {}, function (r) {
			if (r.error) { $('#jg_status').text(r.error); return; }
			var status = (r.admission && r.admission.status) || r.status || 'pending';
			$('#jg_status').text(jgT('Registered') + ' · ' + status);
		});
	});

	$(document).on('click', '#jg_dial', jgDial);

	$(document).on('click', '#jg_panel .jg_room', function () {
		jgOpen($(this).attr('handle'), $(this).attr('room'));
	});

	$(document).on('click', '#jg_join', function () {
		var handle = $(this).attr('handle');
		var room = $(this).attr('room');
		var ticket = $.trim($('#jg_ticket').val());
		$('#jg_status').text(jgT('Joining…'));
		jgPost('/manager/junderground/join', { handle: handle, room: room, ticket: ticket }, function (r) {
			if (r.error) { $('#jg_status').text(r.error); return; }
			jgPresence[handle + '/' + room] = r.presence_id;
			$('#jg_status').text((r.role || 'guest') + (r.ticketed ? ' · ' + jgT('pass') : ''));
			jgSocketOpen(handle, room, r.grant);
			jgOpen(handle, room);
		});
	});

	$(document).on('click', '#jg_leave', function () {
		var handle = $(this).attr('handle');
		var room = $(this).attr('room');
		var key = handle + '/' + room;
		jgPost('/manager/junderground/leave', {
			handle: handle, room: room, presence_id: jgPresence[key] || ''
		}, function (r) {
			delete jgPresence[key];
			jgSocketClose(handle, room);
			$('#jg_status').text(r.error || jgT('Left the room'));
			jgOpen(handle, room);
		});
	});

	$(document).on('click', '.mail_subsection', function () {
		setTimeout(function () { jgConfigWhenReady(10); }, 100);
	});

	if ($('#jg_panel').length) { jgConfigLoad(); }
})();
