// The People app. The first pass owns the house's own crest: scan the drawing on
// the flatbed (or upload a photo from a device without a scanner), then the house
// key signs the record that pins it. Other houses' crests and the vouches between
// them grow here next.

function peopleT(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

// The window is re-fetched after a vouch, a link or a save. Keep the tab and
// the person it was showing so those actions do not send the person back to Me.
var peopleActiveTab = 'me';
var peopleLastPerson = '';

function peopleStatus(text) {
	$('#people_status').text(text || '');
}

function peopleOpener() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/people',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			windowMaker(response);
			if (peopleActiveTab && peopleActiveTab !== 'me') {
				setTimeout(function() {
					peopleTabOpen(peopleActiveTab);
					if (peopleActiveTab === 'people' && peopleLastPerson) { peoplePersonOpen(peopleLastPerson); }
				}, 120);
			}
		}
	});
}

function peopleAfterImport(response) {
	peopleStatus(peopleT('Imported.'));
	peopleOpener();
	var uuid = response && response.crest && response.crest.uuid;
	if (uuid) { setTimeout(function() { peopleCrestDetail(uuid); }, 400); }
}

function peopleCrestMessage(contact) {
	if (!contact) { return; }
	if (contact.phone && typeof jawnLaunchSms === 'function') {
		jawnLaunchSms(contact.phone, '');
		return;
	}
	if (contact.email) {
		window.open('mailto:' + contact.email, '_blank');
		return;
	}
	peopleStatus(peopleT('Link a person with a phone or email first.'));
}

function peopleCrestDetail(uuid) {
	if (!uuid) { return; }
	$.ajax({
		url: '/manager/people/crest/detail',
		type: 'GET',
		data: { uuid: uuid, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || !response.ok) {
				peopleStatus((response && response.error) || peopleT('Could not open that crest.'));
				return;
			}
			var box = $('#people_crest_detail').empty().show();
			$('<button class="people_detail_close">').html('&times;').on('click', function() { box.hide().empty(); }).appendTo(box);
			if (response.image) { $('<img class="people_detail_image">').attr('src', response.image).appendTo(box); }
			$('<h3>').text(response.name || '').appendTo(box);
			$('<div class="people_fp">').text(response.fingerprint || '').appendTo(box);
			$('<div class="people_row_sub">').text(peopleT(response.status || '')).appendTo(box);
			var actions = $('<div class="people_actions">').appendTo(box);
			if (response.home) {
				$('<button>').text(peopleT('Homepage')).on('click', function() { window.open(response.home, '_blank'); }).appendTo(actions);
			}
			if (response.store) {
				$('<button>').text(peopleT('Store')).on('click', function() { window.open(response.store, '_blank'); }).appendTo(actions);
			}
			if (response.contact && (response.contact.phone || response.contact.email)) {
				$('<button>').text(peopleT('Message')).on('click', function() { peopleCrestMessage(response.contact); }).appendTo(actions);
			}
			if (!response.met) {
				$('<button class="people_peer_vouch">').attr('uuid', response.uuid).text(peopleT('I have met this crest')).appendTo(actions);
			}
			if (response.contacts && response.contacts.length) {
				var select = $('<select class="people_contact_link">').appendTo(actions);
				$('<option>').val('').text(peopleT('Link a person')).appendTo(select);
				$.each(response.contacts, function(i, contact) {
					var label = contact.name || contact.app;
					if (contact.phone) { label += ' · ' + contact.phone; }
					else if (contact.email) { label += ' · ' + contact.email; }
					$('<option>').val(contact.app).text(label).appendTo(select);
				});
				if (response.linked_app) { select.val(response.linked_app); }
				$('<button>').text(peopleT('Link')).on('click', function() {
					$.post('/manager/people/crest/link', { uuid: response.uuid, app: select.val(), timestamp: Date.now() }, function() {
						peopleCrestDetail(response.uuid);
					});
				}).appendTo(actions);
			}
			if (box[0] && box[0].scrollIntoView) { box[0].scrollIntoView({ behavior: 'smooth', block: 'nearest' }); }
		},
		error: function() { peopleStatus(peopleT('Could not open that crest.')); }
	});
}

function peopleCrestOpen(uuid) {
	if (!uuid) { return; }
	if ($('.wind[app="people"]').length) {
		peopleCrestDetail(uuid);
		return;
	}
	$.ajax({
		url: '/manager/people',
		type: 'GET',
		data: { timestamp: Date.now() },
		success: function(response) {
			windowMaker(response);
			setTimeout(function() { peopleCrestDetail(uuid); }, 400);
		}
	});
}

$(document).on('click', '.people_crest_row', function(e) {
	if ($(e.target).closest('button, select, input').length) { return; }
	peopleCrestDetail($(this).attr('uuid'));
});

$(document).on('click', '#people_toggle', function() {
	peopleOpener();
});

$(document).on('click', '#people_refresh', function() {
	peopleOpener();
});

// The card is fetched as a blob and handed to a temporary download link: the
// manager's window layer owns ordinary link navigation, so a plain <a href>
// inside a window is not a reliable download.
$(document).on('click', '#people_crest_card', function() {
	if (!window.fetch || !window.URL || !URL.createObjectURL) {
		window.location = '/manager/people/crest/card';
		return;
	}
	peopleStatus(peopleT('Preparing the card…'));
	fetch('/manager/people/crest/card', { credentials: 'same-origin' })
		.then(function(response) {
			if (!response.ok) { throw new Error('HTTP ' + response.status); }
			return response.blob();
		})
		.then(function(blob) {
			var url = URL.createObjectURL(blob);
			var a = document.createElement('a');
			a.href = url;
			a.download = 'crest-card.json';
			document.body.appendChild(a);
			a.click();
			a.remove();
			setTimeout(function() { URL.revokeObjectURL(url); }, 5000);
			peopleStatus(peopleT('Card downloaded.'));
		})
		.catch(function() {
			peopleStatus(peopleT('Could not make the card.'));
		});
});

$(document).on('click', '#people_crest_card_save', function() {
	peopleStatus(peopleT('Saving the card…'));
	$.ajax({
		url: '/manager/people/crest/card/save',
		type: 'POST',
		data: { timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) {
				peopleStatus(peopleT('Saved to') + ' ' + response.path);
			}
			else {
				peopleStatus((response && response.error) || peopleT('Could not save the card.'));
			}
		},
		error: function() { peopleStatus(peopleT('Could not save the card.')); }
	});
});

$(document).on('click', '#people_crest_nfc_write', function() {
	peopleStatus(peopleT('Preparing the code…'));
	$.ajax({
		url: '/manager/people/crest/qr',
		type: 'GET',
		data: { format: 'json', timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || !response.ok || !response.code) {
				peopleStatus((response && response.error) || peopleT('Could not make the code.'));
				return;
			}
			peopleCrestNfcWrite(response.code);
		},
		error: function() { peopleStatus(peopleT('Could not make the code.')); }
	});
});

async function peopleCrestNfcWrite(code) {
	if (!window.JawnNFC || typeof nfc === 'undefined' || !nfc.ndef) {
		peopleStatus(peopleT('No NFC reader here.'));
		return;
	}
	if (nfc.scanning) {
		nfc.scanning = false;
		if (nfc.abort) { nfc.abort.abort(); }
		nfc.writing = true;
		setTimeout(function() { nfc.writing = false; peopleCrestNfcWrite(code); }, 1000);
		return;
	}
	try {
		nfc.writing = true;
		nfc.scanning = false;
		var encoder = new TextEncoder();
		await nfc.ndef.write({
			records: [{
				recordType: 'mime',
				mediaType: 'application/json',
				data: encoder.encode(JSON.stringify({ crest_code: code }))
			}]
		});
		nfc.lastWrite = Date.now();
		peopleStatus(peopleT('Written to the tag.'));
	}
	catch (error) {
		peopleStatus(peopleT('Could not write the tag.'));
	}
	nfc.writing = false;
	nfc.scanning = false;
	if (typeof nfcListener === 'function') { nfcListener(); }
}

$(document).on('click', '#people_crest_qr_button', function() {
	var box = $('#people_crest_qr').empty().text(peopleT('Making the code…'));
	$.ajax({
		url: '/manager/people/crest/qr',
		type: 'GET',
		data: { format: 'json', timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			box.empty();
			if (!response || !response.ok) {
				box.text((response && response.error) || peopleT('Could not make the code.'));
				return;
			}
			if (response.qr) { $('<img>').attr('src', response.qr).appendTo(box); }
			if (response.code) { $('<textarea readonly>').val(response.code).appendTo(box); }
		},
		error: function() { box.text(peopleT('Could not make the code.')); }
	});
});

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

$(document).on('click', '.people_person_relational', function() {
	$('#relational_toggle').trigger('click');
});
