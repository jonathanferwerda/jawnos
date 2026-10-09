// The browser's stores used to wear a key per thing - a note, an ago and a
// duration for every app, a place and a layout for every window, a pick for
// every microphone - so one small thing could run to a hundred keys and a
// family was never written as one. They are folded into a handful of objects
// now: one key per family, read and written whole, and the old keys are read
// once and moved in on the way (each family names its own legacy keys).
//
// The keeper itself is storage-blind, so the same shape serves localStorage and
// sessionStorage; the wrappers below are what the rest of the manager calls.

function jawnosStoreMaker(store) {
	function read(group) {
		var raw = null;
		try { raw = store.getItem(group); } catch (e) { raw = null; }
		var data = {};
		if (raw) {
			try { data = JSON.parse(raw); } catch (e) { data = {}; }
		}
		return (typeof data == 'object' && data !== null) ? data : {};
	}
	function write(group, data) {
		try { store.setItem(group, JSON.stringify(data)); }
		catch (e) { console.log('could not keep ' + group); }
	}
	return {
		read: read,
		// The family's own entry, or the legacy key read once and moved in. The
		// legacy name defaults to the entry's own, since most of them kept it.
		get: function (group, key, legacy) {
			var data = read(group);
			if (data[key] !== undefined) { return data[key]; }
			if (legacy === undefined) { legacy = key; }
			if (!legacy) { return null; }
			var old = null;
			try { old = store.getItem(legacy); } catch (e) { old = null; }
			if (old !== null) {
				data[key] = old;
				write(group, data);
				try { store.removeItem(legacy); } catch (e) {}
			}
			return old;
		},
		set: function (group, key, value, legacy) {
			var data = read(group);
			data[key] = value;
			write(group, data);
			if (legacy === undefined) { legacy = key; }
			if (legacy) {
				try { store.removeItem(legacy); } catch (e) {}
			}
		},
		remove: function (group, key, legacy) {
			var data = read(group);
			delete data[key];
			write(group, data);
			if (legacy === undefined) { legacy = key; }
			if (legacy) {
				try { store.removeItem(legacy); } catch (e) {}
			}
		}
	};
}

var jawnosStore = jawnosStoreMaker(localStorage);
var jawnosSession = jawnosStoreMaker(sessionStorage);

// What a window's app keeps for itself: a note, an ago, a duration, notes.
// They were <app>_note and its kin; they live under app_data now.
function jawnosAppFieldGet(app, field) {
	return jawnosStore.get('app_data', app + '_' + field, app + '_' + field);
}
function jawnosAppFieldSet(app, field, value) {
	jawnosStore.set('app_data', app + '_' + field, value, app + '_' + field);
}
function jawnosAppFieldRemove(app, field) {
	jawnosStore.remove('app_data', app + '_' + field, app + '_' + field);
}

// Where a panel was left (its drop spot) and the whole style dump it wears when
// it opens again; the whiteboard's pen spot keeps them company.
function jawnosWindowPlaceGet(id) {
	return jawnosStore.get('window_places', 'place_' + id, 'pseudonym_location_' + id);
}
function jawnosWindowPlaceSet(id, value) {
	jawnosStore.set('window_places', 'place_' + id, value, 'pseudonym_location_' + id);
}
function jawnosWindowStyleGet(id) {
	return jawnosStore.get('window_places', 'style_' + id, id + '_dynamic');
}
function jawnosWindowStyleSet(id, value) {
	jawnosStore.set('window_places', 'style_' + id, value, id + '_dynamic');
}
function jawnosWhiteboardGet() {
	return jawnosStore.get('window_places', 'whiteboard', 'whiteboard_position');
}
function jawnosWhiteboardSet(value) {
	jawnosStore.set('window_places', 'whiteboard', value, 'whiteboard_position');
}

// The microphone, camera or speaker picked for a device: '<kind><device id>'
// was the key, the pick is the entry's value.
function jawnosDevicePickGet(kind, id) {
	return jawnosStore.get('device_picks', kind + id, kind + id);
}
function jawnosDevicePickSet(kind, id, value) {
	jawnosStore.set('device_picks', kind + id, value, kind + id);
}

// Which pseudonyms the dock shows: on, off, or a button.
function jawnosDockIconGet(name) {
	return jawnosStore.get('dock_icons', name, 'pseudonym_keyboard_' + name);
}
function jawnosDockIconSet(name, value) {
	jawnosStore.set('dock_icons', name, value, 'pseudonym_keyboard_' + name);
}

// A window's top bar size, kept for the session only: tnw_<timestamp> and its
// height pair live under one window_sizes object.
function jawnosWindowSizeGet(timestamp, field) {
	return jawnosSession.get('window_sizes', timestamp + '_' + field, 'tn' + field + '_' + timestamp);
}
function jawnosWindowSizeSet(timestamp, field, value) {
	jawnosSession.set('window_sizes', timestamp + '_' + field, value, 'tn' + field + '_' + timestamp);
}

// Fold one snapshot of the store's own keys into the families. The debrief the
// server keeps is such a snapshot, and it used to be poured straight back into
// localStorage on every load - so the old per-thing keys would have come back
// with it. It is folded on the way in now, and with no snapshot the live store
// is folded instead, one pass at load so the sprawl goes at once rather than a
// touched thing at a time. Keys that belong to no family are written through.
function jawnosStoreFold(source) {
	var keys = [];
	if (source) {
		keys = Object.keys(source);
	}
	else {
		try { for (var i = 0; i < localStorage.length; i++) { keys.push(localStorage.key(i)); } }
		catch (e) { return; }
	}
	for (var k = 0; k < keys.length; k++) {
		var key = keys[k];
		var value = null;
		try { value = source ? source[key] : localStorage.getItem(key); } catch (e) { continue; }
		if (value === null || value === undefined) { continue; }
		if (key.indexOf('pseudonym_location_') === 0) {
			jawnosStore.set('window_places', 'place_' + key.slice('pseudonym_location_'.length), value, key);
		}
		else if (key.slice(-8) === '_dynamic') {
			jawnosStore.set('window_places', 'style_' + key.slice(0, -8), value, key);
		}
		else if (key.indexOf('pseudonym_keyboard_') === 0) {
			jawnosStore.set('dock_icons', key.slice('pseudonym_keyboard_'.length), value, key);
		}
		else if (key == 'whiteboard_position') {
			jawnosStore.set('window_places', 'whiteboard', value, key);
		}
		else if (key.indexOf('audioinput') === 0 || key.indexOf('audiooutput') === 0 || key.indexOf('videoinput') === 0) {
			jawnosStore.set('device_picks', key, value, key);
		}
		else if (key.match(/_(note|notes|ago|duration)$/)) {
			jawnosStore.set('app_data', key, value, key);
		}
		else if (source) {
			try { localStorage.setItem(key, value); } catch (e) {}
		}
	}
}

jawnosStoreFold(null);
