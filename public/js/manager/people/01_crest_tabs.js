$(document).on('click', '#people_crest_scan', function() {
	peopleStatus(peopleT('Scanning…'));
	$.ajax({
		url: '/manager/people/crest/scan',
		type: 'POST',
		data: { timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) {
				peopleStatus(peopleT('Saved.'));
				peopleOpener();
			}
			else {
				peopleStatus((response && response.error) || peopleT('Could not save.'));
			}
		},
		error: function() {
			peopleStatus(peopleT('Could not save.'));
		}
	});
});

$(document).on('click', '#people_crest_capture', function() {
	peopleStatus(peopleT('Taking the picture…'));
	$.ajax({
		url: '/manager/people/crest/capture',
		type: 'POST',
		data: { camera: 0, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) {
				peopleStatus(peopleT('Saved.'));
				peopleOpener();
			}
			else {
				peopleStatus((response && response.error) || peopleT('Could not save.'));
			}
		},
		error: function() {
			peopleStatus(peopleT('Could not save.'));
		}
	});
});

$(document).on('click', '#people_crest_upload_button', function() {
	$('#people_crest_file').trigger('click');
});

$(document).on('change', '#people_crest_file', function() {
	var file = this.files && this.files[0];
	if (!file) { return; }
	var form = new FormData();
	form.append('crest', file);
	peopleStatus(peopleT('Saving…'));
	$.ajax({
		url: '/manager/people/crest/upload',
		type: 'POST',
		data: form,
		processData: false,
		contentType: false,
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) {
				peopleStatus(peopleT('Saved.'));
				peopleOpener();
			}
			else {
				peopleStatus((response && response.error) || peopleT('Could not save.'));
			}
		},
		error: function() {
			peopleStatus(peopleT('Could not save.'));
		}
	});
});

$(document).on('click', '#people_crest_verify_button', function() {
	$('#people_crest_verify_file').trigger('click');
});

$(document).on('change', '#people_crest_verify_file', function() {
	var file = this.files && this.files[0];
	if (!file) { return; }
	var form = new FormData();
	form.append('crest', file);
	$('#people_verify_result').text(peopleT('Checking…'));
	$.ajax({
		url: '/manager/people/crest/verify',
		type: 'POST',
		data: form,
		processData: false,
		contentType: false,
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) {
				var verdict = response.likely ? peopleT('Likely the same drawing') : peopleT('Different drawing');
				$('#people_verify_result').text(verdict + ' — ' + peopleT('distance') + ' ' + response.distance + ' / ' + response.threshold);
			}
			else {
				$('#people_verify_result').text((response && response.error) || peopleT('Could not check.'));
			}
		},
		error: function() {
			$('#people_verify_result').text(peopleT('Could not check.'));
		}
	});
});

$(document).on('click', '#people_crest_import_button', function() {
	$('#people_crest_import_file').trigger('click');
});

$(document).on('change', '#people_crest_import_file', function() {
	var file = this.files && this.files[0];
	if (!file) { return; }
	var reader = new FileReader();
	reader.onload = function() {
		var card = reader.result || '';
		peopleStatus(peopleT('Importing…'));
		$.ajax({
			url: '/manager/people/crest/import',
			type: 'POST',
			data: { card: card, timestamp: Date.now() },
			dataType: 'json',
			success: function(response) {
				if (response && response.ok) {
					peopleAfterImport(response);
				}
				else {
					peopleStatus((response && response.error) || peopleT('Could not import.'));
				}
			},
			error: function() { peopleStatus(peopleT('Could not import.')); }
		});
	};
	reader.readAsText(file);
});

$(document).on('click', '#people_crest_code_import', function() {
	var code = $.trim($('#people_crest_code').val() || '');
	if (!code) { peopleStatus(peopleT('Paste a crest code first.')); return; }
	peopleStatus(peopleT('Importing…'));
	$.ajax({
		url: '/manager/people/crest/import',
		type: 'POST',
		data: { card: code, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) {
				peopleAfterImport(response);
			}
			else {
				peopleStatus((response && response.error) || peopleT('Could not import.'));
			}
		},
		error: function() { peopleStatus(peopleT('Could not import.')); }
	});
});

$(document).on('click', '.people_peer_vouch', function() {
	var uuid = $(this).attr('uuid') || '';
	peopleStatus(peopleT('Saving…'));
	$.ajax({
		url: '/manager/people/crest/vouch',
		type: 'POST',
		data: { uuid: uuid, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) {
				peopleStatus(peopleT('Saved.'));
				peopleOpener();
			}
			else {
				peopleStatus((response && response.error) || peopleT('Could not save.'));
			}
		},
		error: function() { peopleStatus(peopleT('Could not save.')); }
	});
});

$(document).on('click', '#people_house_name_save', function() {
	var name = $('#people_house_name').val() || '';
	peopleStatus(peopleT('Saving…'));
	$.ajax({
		url: '/manager/people/house_name',
		type: 'POST',
		data: { name: name, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) {
				peopleStatus(peopleT('Saved.'));
				peopleOpener();
			}
			else {
				peopleStatus((response && response.error) || peopleT('Could not save.'));
			}
		},
		error: function() {
			peopleStatus(peopleT('Could not save.'));
		}
	});
});

// --- the tabbed window ------------------------------------------------------

function peopleTabOpen(tab) {
	if (!tab) { return; }
	peopleActiveTab = tab;
	var app = $('#people_app');
	if (!app.length) { return; }
	app.find('.people_tab').removeClass('active').filter('[data-tab="' + tab + '"]').addClass('active');
	app.find('.people_panel').removeClass('active').filter('[data-panel="' + tab + '"]').addClass('active');
}

function peoplePersonOpen(uuid) {
	if (!uuid) { return; }
	peopleLastPerson = uuid;
	peopleTabOpen('people');
	$.ajax({
		url: '/manager/people/person',
		type: 'GET',
		data: { uuid: uuid, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || !response.ok) {
				peopleStatus((response && response.error) || peopleT('Could not open that person.'));
				return;
			}
			var box = $('#people_person_card');
			box.html(response.html).show();
			if (box[0] && box[0].scrollIntoView) { box[0].scrollIntoView({ behavior: 'smooth', block: 'nearest' }); }
		},
		error: function() { peopleStatus(peopleT('Could not open that person.')); }
	});
}

function peopleChipJump(chip) {
	var tab = chip.attr('construct-tab');
	var targetApp = chip.attr('construct-app');
	if (!tab) { return; }
	peopleTabOpen(tab);
	var row = $('#people_app .people_panel[data-panel="' + tab + '"] .people_construct_row[app="' + targetApp + '"]');
	row.addClass('open');
	if (row[0] && row[0].scrollIntoView) { row[0].scrollIntoView({ behavior: 'smooth', block: 'center' }); }
}

$(document).on('click', '.people_tab', function() {
	peopleTabOpen($(this).attr('data-tab'));
});

$(document).on('click', '.people_person_row', function(e) {
	if ($(e.target).closest('button, select, input, a').length) { return; }
	peoplePersonOpen($(this).attr('uuid'));
});

$(document).on('click', '.people_construct_row', function(e) {
	if ($(e.target).closest('button, select, input, a').length) { return; }
	$(this).toggleClass('open');
});

$(document).on('click', '.people_member_row', function(e) {
	if ($(e.target).closest('button, select, input, a').length) { return; }
	var uuid = $(this).attr('uuid');
	if (uuid) { peoplePersonOpen(uuid); }
});

$(document).on('click', '.people_chip', function(e) {
	e.stopPropagation();
	peopleChipJump($(this));
});

$(document).on('click', '.people_person_close', function() {
	peopleLastPerson = '';
	$('#people_person_card').hide().empty();
});

$(document).on('click', '.people_person_url', function() {
	var href = $(this).attr('href');
	if (href) { window.open(href, '_blank'); }
});

$(document).on('click', '.people_person_message', function() {
	peopleCrestMessage({ phone: $(this).attr('phone') || '', email: $(this).attr('email') || '' });
});

$(document).on('click', '.people_person_link_crest', function() {
	var app = $(this).attr('app') || '';
	var crest = $(this).closest('.people_person_card').find('.people_person_crest').val() || '';
	if (!app || !crest) { peopleStatus(peopleT('Choose a crest first.')); return; }
	peopleStatus(peopleT('Saving…'));
	$.ajax({
		url: '/manager/people/crest/link',
		type: 'POST',
		data: { uuid: crest, app: app, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) {
				peopleStatus(peopleT('Saved.'));
				peopleOpener();
			}
			else {
				peopleStatus((response && response.error) || peopleT('Could not save.'));
			}
		},
		error: function() { peopleStatus(peopleT('Could not save.')); }
	});
});

// A person's relationship is one of Self, Friend, Stranger or Enemy. It is a
// configuration (like a place's visibility), not an app measure; the call-flow
// matrix reads it.
$(document).on('change', '.people_relationship_select', function() {
	var sel = $(this);
	var app = sel.attr('app') || '';
	if (!app) { return; }
	var value = sel.val() || '';
	var label = sel.find('option:selected').text();
	var rating = sel.find('option:selected').attr('data-rating') || '';
	peopleStatus(peopleT('Saving…'));
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: app, setting: 'relationship', value: value, source: 'people', timestamp: Date.now() },
		success: function() {
			peopleStatus(peopleT('Saved.'));
			var row = $('.people_person_row[app="' + app + '"] .people_relationship');
			if (row.length) {
				if (value) { row.text(label).attr('data-rating', rating).show(); }
				else { row.hide(); }
			}
			sel.closest('.people_relationship_row').find('.people_relationship_rating').text(rating);
		},
		error: function() { peopleStatus(peopleT('Could not save.')); }
	});
});

$(document).on('click', '.people_person_relational', function() {
	var app = $(this).attr('app') || '';
	if (typeof relationalOpener === 'function') { relationalOpener(app); }
	else { $('#relational_toggle').trigger('click'); }
});


// ---- the till's proof of a person -------------------------------------------
// A person's card sets a PIN or writes a tag token. The tag holds the token
// once; the people row keeps only its hash. No handler puts the PIN into a
// status line, a URL or the console.
function peopleTillStatus(box, text) {
	box.find('.people_till_status').text(text || '');
}

$(document).on('click', '.people_till_pin_set', function() {
	var box = $(this).closest('.people_person_till');
	var uuid = box.attr('data-person-uuid') || '';
	var pin = box.find('.people_till_pin').val() || '';
	var confirm = box.find('.people_till_pin_confirm').val() || '';
	if (!uuid) { peopleTillStatus(box, peopleT('No person.')); return; }
	if (!/^\d{4,8}$/.test(pin)) { peopleTillStatus(box, peopleT('A PIN is 4 to 8 digits.')); return; }
	if (pin !== confirm) { peopleTillStatus(box, peopleT('The two PINs do not match.')); return; }
	peopleTillStatus(box, peopleT('Saving…'));
	$.ajax({
		url: '/manager/people/till/pin',
		type: 'POST',
		data: { uuid: uuid, pin: pin, confirm: confirm, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) {
				box.find('.people_till_pin, .people_till_pin_confirm').val('');
				peopleTillStatus(box, peopleT('Saved.'));
			}
			else {
				peopleTillStatus(box, (response && response.error) || peopleT('Could not save.'));
			}
		},
		error: function() { peopleTillStatus(box, peopleT('Could not save.')); }
	});
});

$(document).on('click', '.people_till_tag_write', function() {
	var box = $(this).closest('.people_person_till');
	var uuid = box.attr('data-person-uuid') || '';
	if (!uuid) { peopleTillStatus(box, peopleT('No person.')); return; }
	peopleTillStatus(box, peopleT('Preparing the tag…'));
	$.ajax({
		url: '/manager/people/till/tag',
		type: 'POST',
		data: { uuid: uuid, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || !response.ok || !response.token) {
				peopleTillStatus(box, (response && response.error) || peopleT('Could not make the tag.'));
				return;
			}
			peopleTillTagWrite(box, response.token);
		},
		error: function() { peopleTillStatus(box, peopleT('Could not make the tag.')); }
	});
});

async function peopleTillTagWrite(box, token) {
	if (!window.JawnNFC || typeof nfc === 'undefined' || !nfc.ndef || typeof nfc.ndef.write !== 'function') {
		peopleTillStatus(box, peopleT('No NFC reader here. The tag token is') + ' ' + token);
		return;
	}
	if (nfc.writing) {
		peopleTillStatus(box, peopleT('Another tag is still waiting to be written.'));
		return;
	}
	nfc.writing = true;
	peopleTillStatus(box, peopleT('Hold the tag to the phone…'));
	var timer = null;
	try {
		var encoder = new TextEncoder();
		await Promise.race([
			nfc.ndef.write({
				records: [{
					recordType: 'mime',
					mediaType: 'application/json',
					data: encoder.encode(JSON.stringify({ till_token: token }))
				}]
			}),
			new Promise(function(resolve, reject) {
				timer = setTimeout(function() { reject(new Error('timeout')); }, 25000);
			})
		]);
		nfc.lastWrite = Date.now();
		peopleTillStatus(box, peopleT('Written to the tag.'));
	}
	catch (error) {
		try { if (nfc.ndef.cancelWrite) { nfc.ndef.cancelWrite(); } } catch (e) {}
		if (error && error.message === 'timeout') {
			peopleTillStatus(box, peopleT('No tag found. Hold the tag to the phone and try again.'));
		}
		else {
			peopleTillStatus(box, peopleT('Could not write the tag. The tag may be too small; try a larger one.'));
		}
	}
	finally {
		clearTimeout(timer);
		nfc.writing = false;
		if (typeof nfcListener === 'function') { nfcListener(); }
	}
}
