// The Store's floorplan: a picture of the room with seats placed on it, and an
// open order at a seat. It is the wait-staff view of the Register - tapping a
// table hands that table's order to the till, and tapping an empty table starts
// one there. The picture and the seats are one value the server keeps; the
// order is the same register order every other part of the till reads.
var storeFloorData = {
	floor: { seats: [] },
	orders: [],
	editing: false,
	placing: false,
	seat: ''
};

function storeFloorT(text) {
	var args = Array.prototype.slice.call(arguments);
	if (typeof jawnosT === 'function') {
		return jawnosT.apply(null, args);
	}
	return String(text).replace(/\{(\d+)\}/g, function(m, i) {
		return args[(+i) + 1] !== undefined ? args[(+i) + 1] : m;
	});
}

function storeFloorStatus(text) {
	var status = $('#store_floor_status');
	if (status.length) { status.text(text || ''); }
}

function storeFloorOpen() {
	$('#store_floor').addClass('open');
	storeFloorStatus('');
	storeFloorLoad();
}

function storeFloorClose() {
	$('#store_floor').removeClass('open');
	storeFloorData.seat = '';
	storeFloorData.placing = false;
}

function storeFloorLoad(done) {
	$.getJSON('/manager/store/register/floor', { timestamp: Date.now() }, function(r) {
		if (!r || !r.ok) { return; }
		storeFloorData.floor = r.floor || { seats: [] };
		storeFloorData.orders = r.orders || [];
		if (storeFloorData.seat && !storeFloorSeatById(storeFloorData.seat)) {
			storeFloorData.seat = '';
		}
		storeFloorRender();
		if (typeof done === 'function') { done(); }
	});
}

function storeFloorSeatById(id) {
	var seats = (storeFloorData.floor && storeFloorData.floor.seats) || [];
	for (var i = 0; i < seats.length; i++) {
		if (seats[i].id === id) { return seats[i]; }
	}
	return null;
}

function storeFloorOrderFor(seatId) {
	for (var i = 0; i < storeFloorData.orders.length; i++) {
		if (storeFloorData.orders[i].seat === seatId) { return storeFloorData.orders[i]; }
	}
	return null;
}

function storeFloorPost(url, data, done) {
	data = data || {};
	data.timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'POST',
		data: data,
		dataType: 'json'
	}).done(function(r) {
		if (!r || !r.ok) {
			storeFloorStatus((r && r.error) || storeFloorT('That did not work.'));
			return;
		}
		storeFloorStatus('');
		if (typeof done === 'function') { done(r); }
	}).fail(function() {
		storeFloorStatus(storeFloorT('That did not work.'));
	});
}

function storeFloorSave(params, done) {
	storeFloorPost('/manager/store/register/floor/plan', params, function(r) {
		storeFloorData.floor = r.floor || storeFloorData.floor;
		storeFloorRender();
		if (typeof done === 'function') { done(r); }
	});
}

function storeFloorRender() {
	var floor = storeFloorData.floor || { seats: [] };
	var image = floor.image || '';
	$('#store_floor_name_label').text(floor.name || '');
	var picture = $('#store_floor_image');
	if (image) { picture.attr('src', image).show(); }
	else { picture.removeAttr('src').hide(); }
	$('#store_floor_empty').toggle(!image);
	$('#store_floor_name').val(floor.name || '');
	$('#store_floor_edit').text(storeFloorData.editing ? storeFloorT('Done editing') : storeFloorT('Edit plan'));
	$('#store_floor_edit_panel').toggle(storeFloorData.editing);
	$('#store_floor_seat_view').toggle(!!storeFloorData.seat);

	var layer = $('#store_floor_seats').empty();
	$.each(floor.seats || [], function(i, seat) {
		var order = storeFloorOrderFor(seat.id);
		var button = $('<button type="button" class="store_floor_seat"></button>')
			.attr('data-seat', seat.id)
			.attr('aria-label', seat.name || storeFloorT('Table'))
			.css({ left: seat.x + '%', top: seat.y + '%' })
			.toggleClass('taken', !!order)
			.toggleClass('selected', storeFloorData.seat === seat.id)
			.toggleClass('editing', storeFloorData.editing);
		button.append($('<span class="store_floor_seat_name"></span>').text(seat.name || storeFloorT('Table')));
		if (order) {
			var total = (order.totals && order.totals.total) ? order.totals.total : 0;
			button.append($('<span class="store_floor_seat_total"></span>').text(numeral(total).format('$0.00')));
			// Only a named customer is worth a second line; a walk-in stays quiet.
			if (order.customer && order.customer.cx) {
				button.append($('<span class="store_floor_seat_customer"></span>').text(order.customer.name || ''));
			}
		}
		layer.append(button);
	});
	storeFloorRenderSeatList(floor);
	storeFloorRenderSeat();
}

// The editor's list of placed seats: a tap selects one, so a table behind a
// big picture is still reachable to rename or remove.
function storeFloorRenderSeatList(floor) {
	var list = $('#store_floor_seat_list').empty();
	if (!storeFloorData.editing) { list.hide(); return; }
	list.show();
	$.each(floor.seats || [], function(i, seat) {
		var item = $('<button type="button" class="store_floor_seat_list_item"></button>')
			.attr('data-seat', seat.id)
			.toggleClass('selected', storeFloorData.seat === seat.id);
		item.append($('<span></span>').text(seat.name || storeFloorT('Table')));
		item.append($('<b></b>').text(storeFloorT('{0} seats', seat.seats || 0)));
		list.append(item);
	});
}

function storeFloorRenderSeat() {
	var seat = storeFloorData.seat ? storeFloorSeatById(storeFloorData.seat) : null;
	var view = $('#store_floor_seat_view');
	if (!seat) { view.hide(); return; }
	var order = storeFloorOrderFor(seat.id);
	$('#store_floor_seat_title').text(seat.name || storeFloorT('Table'));
	var detail = $('#store_floor_seat_detail').empty();
	detail.append($('<div></div>').text(storeFloorT('{0} seats', seat.seats || 0)));
	if (order) {
		var customer = order.customer && order.customer.name ? order.customer.name : storeFloorT('Customer');
		detail.append($('<div></div>').text(customer));
		var total = (order.totals && order.totals.total) ? order.totals.total : 0;
		detail.append($('<div class="store_floor_seat_detail_total"></div>').text(numeral(total).format('$0.00')));
		var lines = (order.items || []).length;
		detail.append($('<div></div>').text(storeFloorT('{0} lines', lines)));
	}
	else {
		detail.append($('<div></div>').text(storeFloorT('Nobody is sitting here yet.')));
	}
	$('#store_floor_seat_open').toggle(!!order && !storeFloorData.editing);
	$('#store_floor_seat_clear').toggle(!!order && !storeFloorData.editing);
	$('#store_floor_seat_remove').toggle(storeFloorData.editing);
	view.show();
}

// Tap a table. A table with an order hands it to the till; an empty one starts
// an order there, so the next tap is on the same order.
function storeFloorSeatOpen(seatId, order) {
	if (order) {
		storeFloorClose();
		storeRegisterOpenOrder(order.id);
		return;
	}
	storeFloorPost('/manager/store/register/floor/seat', { seat: seatId }, function(r) {
		storeFloorLoad(function() {
			if (r && r.order) {
				storeFloorClose();
				storeRegisterOpenOrder(r.order.id);
			}
		});
	});
}

function storeFloorSeatRemove() {
	var seat = storeFloorData.seat;
	if (!seat) { return; }
	var orders = $.grep(storeFloorData.orders, function(order) { return order.seat === seat; });
	var seats = $.grep((storeFloorData.floor.seats || []), function(one) { return one.id !== seat; });
	var unseat = function(index) {
		if (index >= orders.length) {
			storeFloorData.seat = '';
			storeFloorSave({ seats: seats });
			return;
		}
		storeFloorPost('/manager/store/register/floor/seat', { id: orders[index].id, seat: '' }, function() {
			unseat(index + 1);
		});
	};
	unseat(0);
}

function storeFloorPlaceSeat(clientX, clientY) {
	var plan = $('#store_floor_canvas');
	if (!plan.length) { plan = $('#store_floor_plan'); }
	if (!plan.length) { return; }
	var rect = plan[0].getBoundingClientRect();
	if (!rect.width || !rect.height) { return; }
	var x = Math.min(100, Math.max(0, ((clientX - rect.left) / rect.width) * 100));
	var y = Math.min(100, Math.max(0, ((clientY - rect.top) / rect.height) * 100));
	var seats = (storeFloorData.floor.seats || []).slice();
	var name = $.trim($('#store_floor_seat_name').val() || '');
	if (!name.length) { name = storeFloorT('Table {0}', seats.length + 1); }
	var covers = parseInt($('#store_floor_seat_covers').val(), 10);
	if (!(covers > 0)) { covers = 1; }
	seats.push({
		id: 'seat-' + Date.now().toString(36) + '-' + Math.floor(Math.random() * 1000),
		name: name,
		x: Math.round(x * 100) / 100,
		y: Math.round(y * 100) / 100,
		seats: covers,
		kind: $('#store_floor_seat_kind').val() || 'table'
	});
	storeFloorData.placing = false;
	$('#store_floor_seat_place').removeClass('active');
	$('#store_floor_seat_name').val('');
	storeFloorSave({ seats: seats }, function() {
		storeFloorStatus(storeFloorT('The table is placed.'));
	});
}

$(document).on('click', '#store_floor_open', function() {
	// The floor sits under the register; when a waiter asks for it from the till
	// the till steps aside, and the next tap on a table brings it back.
	if (typeof storeRegisterClose === 'function') { storeRegisterClose(); }
	storeFloorOpen();
});

$(document).on('click', '#store_floor_close', function() {
	storeFloorClose();
});

$(document).on('click', '#store_floor_edit', function() {
	storeFloorData.editing = !storeFloorData.editing;
	storeFloorData.placing = false;
	$('#store_floor_seat_place').removeClass('active');
	storeFloorStatus('');
	storeFloorRender();
	if (storeFloorData.editing) { storeFloorData.seat = ''; storeFloorRenderSeat(); }
});

$(document).on('click', '#store_floor_seat_place', function() {
	if (!storeFloorData.editing) { return; }
	storeFloorData.placing = !storeFloorData.placing;
	$(this).toggleClass('active', storeFloorData.placing);
	storeFloorStatus(storeFloorData.placing ? storeFloorT('Tap the picture where the table sits.') : '');
});

$(document).on('click', '#store_floor_plan', function(e) {
	if (!storeFloorData.editing || !storeFloorData.placing) { return; }
	if ($(e.target).closest('.store_floor_seat').length) { return; }
	storeFloorPlaceSeat(e.clientX, e.clientY);
});

$(document).on('click', '.store_floor_seat', function(e) {
	e.stopPropagation();
	var id = $(this).attr('data-seat');
	if (storeFloorData.editing) {
		storeFloorData.seat = id;
		storeFloorRender();
		return;
	}
	storeFloorSeatOpen(id, storeFloorOrderFor(id));
});

$(document).on('click', '.store_floor_seat_list_item', function() {
	storeFloorData.seat = $(this).attr('data-seat') || '';
	storeFloorRender();
});

$(document).on('click', '#store_floor_seat_open', function() {
	var seat = storeFloorData.seat;
	var order = seat ? storeFloorOrderFor(seat) : null;
	if (order) { storeFloorSeatOpen(seat, order); }
});

$(document).on('click', '#store_floor_seat_clear', function() {
	var seat = storeFloorData.seat;
	var order = seat ? storeFloorOrderFor(seat) : null;
	if (!order) { return; }
	storeFloorPost('/manager/store/register/floor/seat', { id: order.id, seat: '' }, function() {
		storeFloorStatus(storeFloorT('The order is off the table; the tab is still at the register.'));
		storeFloorLoad();
	});
});

$(document).on('click', '#store_floor_seat_remove', function() {
	storeFloorSeatRemove();
});

$(document).on('change', '#store_floor_name', function() {
	storeFloorSave({ name: $(this).val() || '' });
});

$(document).on('change', '#store_floor_image_file', function() {
	var file = (this.files || [])[0];
	if (!file) { return; }
	var field = this;
	var reader = new FileReader();
	reader.onload = function() {
		var image = new Image();
		image.onload = function() {
			// The picture is kept in the database, so it is resized here rather
			// than stored at whatever a phone camera produced.
			var max = 1600;
			var scale = Math.min(1, max / Math.max(image.width, image.height));
			var canvas = document.createElement('canvas');
			canvas.width = Math.max(1, Math.round(image.width * scale));
			canvas.height = Math.max(1, Math.round(image.height * scale));
			canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
			var data = canvas.toDataURL('image/jpeg', 0.82);
			storeFloorSave({ image: data }, function() {
				storeFloorStatus(storeFloorT('The picture is saved.'));
				field.value = '';
			});
		};
		image.onerror = function() { storeFloorStatus(storeFloorT('That picture could not be read.')); };
		image.src = reader.result;
	};
	reader.readAsDataURL(file);
});
