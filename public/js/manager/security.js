/* [[js-split]]
   security.js is part 1. The rest live in security/ in name order:
     01_house_key.js - device-held shares - passkeys WebAuthn - Security own door
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */


// The paper-share QR images come back as data URIs and are also saved under
// ~/.jawnos_paper_shares/<stamp>/ on this machine. The page shows them once.
function jawnosShareQr(target, dirTarget, qr) {
	var $t = $(target).empty();
	var $d = $(dirTarget).empty();
	if (!qr || !qr.images || !qr.images.length) { return; }
	var share = (typeof jawnosT === 'function') ? jawnosT('Share') : 'Share';
	qr.images.forEach(function (img) {
		var box = $('<div>').css({ display: 'inline-block', textAlign: 'center', margin: '6px' });
		$('<img>').attr({ src: img.data, alt: share + ' ' + img.index, title: share + ' ' + img.index })
			.css({ width: '160px', height: '160px' }).appendTo(box);
		$('<div>').text(share + ' ' + img.index).css({ fontSize: '12px' }).appendTo(box);
		box.appendTo($t);
	});
	var saved = (typeof jawnosT === 'function') ? jawnosT('Saved in') : 'Saved in';
	$d.text(saved + ' ' + qr.dir + (qr.missing ? ' (' + qr.missing + ' not made)' : ''));
}

$(document).on('click', '#security_toggle', function() {

	var url = '/manager/security';

	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response.html)
		}, error: function (response) { 
		}
	});
});

$(document).on('click', '#padlock_gate_enable, #padlock_gate_disable', function() {
	var button = $(this);
	var url = (button.attr('id') == 'padlock_gate_enable')
		? '/manager/security/gate/enable'
		: '/manager/security/gate/disable';
	button.prop('disabled', true);
	$.ajax({
		url: url,
		type: 'POST',
		data: { timestamp: Date.now() },
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				$('#padlock_set_status').text(response && response.error ? response.error : 'The gate did not change.');
				return;
			}
			$('#security').replaceWith(response.html);
			appointment_chron();
			// the taskbar padlock is rendered with the layout, so enabling the
			// gate used to leave it hidden until a refresh; the reply carries
			// the new state and the same broadcast reaches other screens
			if (typeof response.has_padlock !== 'undefined') {
				$('#lock_session').toggle(!!response.has_padlock);
			}
		},
		error: function() {
			button.prop('disabled', false);
			$('#padlock_set_status').text('The gate did not change.');
		}
	});
});

$(document).on('change', '#padlock_contexts', function() {
	var contexts = $(this).val();
	contexts = JSON.stringify(contexts); 
	settingSetter({ 'app': '__president', 'setting': 'padlock_contexts', 'value': contexts });
});

// Private is a lock turned by a fingerprint, not a place level. The padlock
// partial in the overlay is the same one Gallery, Folders and Music use, so the
// computer's reader, the phone and the recovery path all land in the same place.
$(document).on('click', '#security_private_unlock', function() {
	$('#security_private_status').text('');
	$('#security_private_padlock').show();
});

$(document).on('click', '#security_private_close', function() {
	$('#security_private_padlock').hide();
});

$(document).on('click', '#security_private_lock', function() {
	$('#security_private_padlock').hide();
	$.post('/manager/security/media_lock', {
		app: 'private',
		device_uuid: (typeof jawnDeviceUuid === 'function') ? jawnDeviceUuid() : '',
		browser_tab_id: (typeof jawnosMediaTab === 'function') ? jawnosMediaTab() : ''
	}, function() {
		if (typeof jawnosPrivateRefresh === 'function') { jawnosPrivateRefresh(0); }
		$('#security_private_status').text((typeof jawnosT === 'function') ? jawnosT('Private apps are hidden again.') : 'Private apps are hidden again.');
	}, 'json');
});

$(document).on('change', '#padlock_gate', function() {
	settingSetter({ 'app': '__president', 'setting': 'padlock_gate', 'value': $(this).val() });
});

// Off / shadow / enforce for the app-only manager gate. Shadow is the safe way
// to see what a browser would lose before it is turned on for real.
$(document).on('change', '#app_access', function() {
	settingSetter({ 'app': '__president', 'setting': 'app_access', 'device': 'all', 'value': $(this).val() });
});

// The phone's own biometric unlock: the Android app makes a Keystore key that
// the OS releases only after the fingerprint prompt, and registers its public
// half here. The locked page can also enroll on the spot. An already-enrolled
// fingerprint must pass before a new one can replace it.
$(document).on('click', '#padlock_biometric_enroll_button', function() {
	var button = $(this);
	var status = $('#padlock_biometric_status');
	if (typeof jawnosBiometricEnroll !== 'function') {
		status.text('Fingerprint unlock is not available in this app.');
		return;
	}
	var enrolled = (button.attr('data-enrolled') === '1');
	button.prop('disabled', true);
	var confirmed = enrolled
		? jawnosBiometricVerify(function (text) { status.text(text); })
		: Promise.resolve(null);
	confirmed.then(function (proof) {
		return jawnosBiometricEnroll(function (text) { status.text(text); }, proof);
	}).then(function() {
		button.prop('disabled', false);
		button.attr('data-enrolled', '1');
		button.text("Replace this phone's fingerprint");
		status.text(enrolled
			? 'Replaced. This phone unlocks with the new fingerprint.'
			: 'Enrolled. This phone can unlock its own screen with your fingerprint.');
	}).catch(function(err) {
		button.prop('disabled', false);
		status.text((typeof jawnosBiometricError === 'function') ? jawnosBiometricError(err) : 'Fingerprint enrollment failed.');
	});
});


$(document).on('click', '.security_view_select', function() {
	var view = $(this).attr('view');
	settingSetter({
		'app': '__president',
		'setting': 'security_view',
		'value': view
	});
	$('.security_view').hide();
	$('.security_view[view="' + view + '"]').show();
	$('.security_view_select').css({ 'background-color': 'lightgray' });
	$('.security_view_select[view="' + view +'"]').css({ 'background-color': 'lightgreen' });


	var url = '/manager/security';

	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { timestamp: timestamp, security_view: view },
		success: function(response) {
			$('#security').replaceWith(response.html);
			appointment_chron();
		}, error: function (response) { 
		}
	});
});

$(document).on('click', '.neighbour_link_updater', function() {
	var nlu = $(this);
	var nl = nlu.closest('.neighbour_link');
	var uuid = nl.attr('uuid');
	var nlus = $('.neighbour_link_updater_selection[uuid="' + uuid + '"]');
	if (nlus.is(':visible')) {
		nlus.hide();
	}
	else {
		nlus.show();
	}
});

$(document).on('click', '.neighbour_link_privilege_change', function() {
	var privilege = $(this).attr('privilege');
	var nl = $(this).closest('.neighbour_link_updater_selection');
	var uuid = nl.attr('uuid');
	$.ajax({
		url: '/manager/security/neighbour_link_privilege',
		type: 'POST',
		data: { uuid: uuid, privilege: privilege },
		success: function(response) {
			$('#security').html(response);
			appointment_chron();
		}
	});
});


$(document).on('click', '.neighbour_link_credential', function() {
	var nlr = $(this).closest('.neighbour_link_request');
	var privilege = $(this).attr('privilege');
	var credential = nlr.attr('credential');
	var remote_address = nlr.attr('remote_address');
	var local_address = nlr.attr('local_address');
	var my_name = nlr.attr('my_name');
	$.ajax({
		url: '/manager/security/neighbour_link_assign',
		type: 'POST',
		data: {
			privilege: privilege,
			remote_address: remote_address,
			local_address: local_address,
			my_name: my_name,
			credential: credential
		},
		success: function(response) {
			jawnosAlertClose();
		}
	});
});

$(document).on('click', '.neighbour_link_delete', function() {
	var uuid = $(this).closest('.neighbour_link').attr('uuid');
	$.ajax({
		url: '/manager/security/neighbour_link_delete',
		type: 'POST',
		data: { uuid: uuid },
		success: function(response) {
			$('#security').html(response);
			appointment_chron();
		}
	});
});

$(document).on('click', '.device_revoke', function() {
	var uuid = $(this).closest('.paired_device').attr('uuid');
	$.ajax({
		url: '/manager/security/device_revoke',
		type: 'POST',
		data: { uuid: uuid },
		success: function(response) {
			$('#security').replaceWith(response.html);
			appointment_chron();
		}
	});
});

// Who a device belongs to. The device in the hand may not be demoted below
// citizen: the live session keeps its privilege until the next login, and that
// login would read the lower one.
$(document).on('change', '.device_person_select', function() {
	var select = $(this);
	$.ajax({
		url: '/manager/security/person_assign',
		type: 'POST',
		data: { device_uuid: select.attr('device'), person_uuid: select.val() || '', security_view: 'devices' },
		success: function(response) {
			if (response && response.html) {
				$('#security').replaceWith(response.html);
				appointment_chron();
			}
			else {
				jawnosAlert(response && response.error ? response.error : 'Could not assign that person');
			}
		},
		error: function() {
			jawnosAlert('Could not assign that person');
		}
	});
});

$(document).on('click', '#person_add_button', function() {
	var name = ($('#person_new_name').val() || '').trim();
	if (!name) { jawnosAlert('Type a name first'); return; }
	$.ajax({
		url: '/manager/security/person_create',
		type: 'POST',
		data: { name: name, privilege: $('#person_new_privilege').val() || 'resident', security_view: 'devices' },
		success: function(response) {
			if (response && response.html) {
				$('#security').replaceWith(response.html);
				appointment_chron();
			}
			else {
				jawnosAlert('Could not add that person');
			}
		},
		error: function() {
			jawnosAlert('Could not add that person');
		}
	});
});

$(document).on('click', '.person_revoke', function() {
	var button = $(this);
	var row = button.closest('.person_row');
	var uuid = row.attr('uuid');
	var original = button.text();
	if (button.attr('armed') !== 'yes') {
		button.attr('armed', 'yes');
		button.css({ 'background-color': 'red' });
		button.text(typeof jawnosT === 'function' ? jawnosT('Press again') : 'Press again');
		setTimeout(function() {
			button.attr('armed', 'no');
			button.css({ 'background-color': '' });
			button.text(original);
		}, 3000);
		return;
	}
	button.attr('armed', 'no');
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/security/person_revoke',
		type: 'POST',
		data: { person_uuid: uuid, security_view: 'devices' },
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				jawnosAlert(response && response.error ? response.error : 'Could not revoke that person');
				button.text(original);
				return;
			}
			$('#security').replaceWith(response.html);
			appointment_chron();
		},
		error: function() {
			button.prop('disabled', false);
			button.text(original);
			jawnosAlert('Could not revoke that person');
		}
	});
});

$(document).on('click', '#recovery_create', function() {
	$.ajax({
		url: '/manager/security/recovery/create',
		type: 'POST',
		data: { timestamp: Date.now(), security_view: 'recovery' },
		success: function(response) {
			if (!response || !response.ok || !response.code) {
				jawnosAlert('Could not make a recovery code');
				return;
			}
			$('#security').replaceWith(response.html);
			appointment_chron();
			$('#recovery_code_display').show();
			$('#recovery_code_value').text(response.code);
		},
		error: function() {
			jawnosAlert('Could not make a recovery code');
		}
	});
});

$(document).on('click', '#shares_create', function() {
	$.ajax({
		url: '/manager/security/shares/create',
		type: 'POST',
		data: { security_view: 'recovery' },
		success: function(response) {
			if (!response || !response.ok || !response.shares) {
				jawnosAlert('Could not make the shares');
				return;
			}
			$('#security').replaceWith(response.html);
			appointment_chron();
			$('#shares_display').show();
			$('#shares_value').text((response.shares || []).join('\n'));
			jawnosShareQr('#shares_qr', '#shares_qr_dir', response.qr);
		},
		error: function() {
			jawnosAlert('Could not make the shares');
		}
	});
});

$(document).on('click', '.device_request_decide', function() {
	var row = $(this).closest('.device_request');
	var uuid = row.attr('uuid');
	var decision = $(this).attr('decision');
	$.ajax({
		url: '/manager/security/device_request_decide',
		type: 'POST',
		data: { uuid: uuid, decision: decision },
		success: function(response) {
			if (response && response.html) {
				$('#security').replaceWith(response.html);
				appointment_chron();
			}
		}
	});
});

$(document).on('change', '#vault_share_tick', function() {
	settingSetter({ 'app': '__president', 'setting': 'vault_share', 'value': ($(this).is(':checked') ? 'yes' : 'no') });
});

$(document).on('click', '#rotate_key', function() {
	var button = $(this);
	if (button.attr('armed') != 'yes') {
		button.attr('armed', 'yes');
		button.css({ 'background-color': 'red' });
		$('#rotate_key_note').text('Press again to rotate: sessions restart and the recovery code is set aside.');
		setTimeout(function() {
			button.css({ 'background-color': '' });
			button.attr('armed', 'no');
		}, 3000);
		return;
	}
	button.attr('armed', 'no');
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/security/rotate_key',
		type: 'POST',
		data: { timestamp: Date.now() },
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				$('#rotate_key_note').text('Rotation did not run.');
				return;
			}
			$('#security').replaceWith(response.html);
			appointment_chron();
			$('#rotate_key_note').text('Rotated. Write down a new recovery code. Sealed files re-seal in the background, and linked machines are handed the new key.');
		},
		error: function() {
			button.prop('disabled', false);
			$('#rotate_key_note').text('Rotation did not run.');
		}
	});
});

$(document).on('click', '#legacy_reseal', function() {
	var button = $(this);
	button.prop('disabled', true);
	$('#legacy_reseal_note').text('Upgrading...');
	$.ajax({
		url: '/manager/security/legacy_reseal',
		type: 'POST',
		data: { timestamp: Date.now() },
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				$('#legacy_reseal_note').text('The upgrade did not run.');
				return;
			}
			var local = response.local || {};
			var mesh = response.mesh || {};
			var here = (local.settings || 0) + (local.security || 0) + (local.links || 0);
			$('#legacy_reseal_note').text('Upgraded here: ' + here + '. On linked machines: ' + (mesh.upgraded || 0) + ' (' + (mesh.ok || 0) + ' of ' + (mesh.asked || 0) + ' answered' + ((mesh.failed || 0) ? ', ' + mesh.failed + ' not answering yet' : '') + ').');
		},
		error: function() {
			button.prop('disabled', false);
			$('#legacy_reseal_note').text('The upgrade did not run.');
		}
	});
});

$(document).on('click', '.signatorial_selection', function() {
	var sig = $(this);
	var file = sig.attr('file');
	$.ajax({
		url: '/manager/security/signatorial/selection',
		type: 'POST',
		data: { file: file },
		success: function(response) {
			$('#security').replaceWith(response.html);
		}
	});



});
