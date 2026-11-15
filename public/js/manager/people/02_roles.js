// ---- staff roles -----------------------------------------------------------
// Two lists, one idea. The Staff roles card in the People tab edits the house's
// role catalog: a role is a name, a department and a set of permission keys the
// route map knows. A person's card then ticks the roles that person holds.
// Neither list can raise a tier: a role only names an app surface, so the
// Configure, Security and Power desks are never among the keys on offer.

// A permission key is a file's word, not a label: 'box_office' reads as
// 'Box office'. Anything the catalog does not know falls back to the English
// words the key is made of.
function peopleRoleKeyLabel(key) {
	var label = String(key || '').replace(/_/g, ' ');
	if (!label) { return ''; }
	return label.charAt(0).toUpperCase() + label.slice(1);
}

// The key list is rendered once by the template onto the card, so a row added
// in the browser offers exactly the keys the server would accept.
function peopleRolePermissionKeys() {
	var raw = $('#people_roles_card').attr('data-permission-keys') || '';
	return raw ? raw.split(/\s+/) : [];
}

function peopleRoleStatus(text) {
	$('#people_roles_status').text(text || '');
}

function peopleRoleRow(role) {
	role = role || {};
	var keys = peopleRolePermissionKeys();
	var held = {};
	var permissions = role.permissions || [];
	for (var i = 0; i < permissions.length; i++) { held[permissions[i]] = 1; }

	var row = $('<div>').addClass('people_role_row')
		.attr('data-role-uuid', role.uuid || '')
		.attr('data-role-builtin', role.builtin ? '1' : '0');

	$('<input>').addClass('people_role_name')
		.attr({ type: 'text', maxlength: '60', placeholder: peopleT('Role name') })
		.val(role.name || '').appendTo(row);
	$('<input>').addClass('people_role_department')
		.attr({ type: 'text', maxlength: '60', placeholder: peopleT('Department') })
		.val(role.department || '').appendTo(row);

	var group = $('<div>').addClass('people_role_keys').appendTo(row);
	for (var k = 0; k < keys.length; k++) {
		var label = $('<label>').addClass('people_role_key').appendTo(group);
		$('<input>').addClass('people_role_permission')
			.attr({ type: 'checkbox', value: keys[k] })
			.prop('checked', held[keys[k]] ? true : false)
			.appendTo(label);
		label.append(document.createTextNode(peopleT(peopleRoleKeyLabel(keys[k]))));
	}

	$('<button>').addClass('people_role_delete')
		.attr({ type: 'button', hint: peopleT('Delete role') })
		.text(peopleT('Delete')).appendTo(row);

	return row;
}

// The server's answer is the list: it drops an empty role and gives a new one
// the id its name makes, so redrawing from the response is what lets the next
// save update that row instead of adding it again.
function peopleRoleRender(roles) {
	var list = $('#people_roles_list');
	if (!list.length) { return; }
	list.empty();
	for (var i = 0; i < (roles || []).length; i++) {
		list.append(peopleRoleRow(roles[i]));
	}
}

function peopleRoleCollect() {
	var list = [];
	var bad = null;
	$('#people_roles_list .people_role_row').each(function() {
		var row = $(this);
		var name = $.trim(row.find('.people_role_name').val() || '');
		if (!name) { bad = row.find('.people_role_name'); return false; }
		var permissions = [];
		row.find('.people_role_permission:checked').each(function() {
			permissions.push($(this).val());
		});
		list.push({
			uuid: row.attr('data-role-uuid') || '',
			name: name,
			department: $.trim(row.find('.people_role_department').val() || ''),
			permissions: permissions,
			builtin: row.attr('data-role-builtin') === '1'
		});
	});
	return { list: list, bad: bad };
}

$(document).on('click', '.people_role_add', function() {
	var list = $('#people_roles_list');
	if (!list.length) { return; }
	var row = peopleRoleRow({});
	list.append(row);
	peopleRoleStatus('');
	row.find('.people_role_name').trigger('focus');
});

$(document).on('click', '.people_role_save_all', function() {
	var collected = peopleRoleCollect();
	if (collected.bad) {
		peopleRoleStatus(peopleT('Every role needs a name.'));
		collected.bad.trigger('focus');
		return;
	}
	peopleRoleStatus(peopleT('Saving…'));
	$.ajax({
		url: '/manager/people/roles/save',
		type: 'POST',
		data: { roles: JSON.stringify(collected.list), timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || !response.ok) {
				peopleRoleStatus((response && response.error) || peopleT('Could not save the roles.'));
				return;
			}
			peopleRoleRender(response.roles);
			peopleRoleStatus(peopleT('Saved.'));
		},
		error: function() {
			peopleRoleStatus(peopleT('Could not save the roles.'));
		}
	});
});

// A role added in this browser has no id yet, so removing it is just dropping
// the row. A kept role is its own call, because its id is what the people who
// hold it point at.
$(document).on('click', '.people_role_delete', function() {
	var row = $(this).closest('.people_role_row');
	var uuid = row.attr('data-role-uuid') || '';
	if (!uuid) {
		row.remove();
		peopleRoleStatus('');
		return;
	}
	peopleRoleStatus(peopleT('Saving…'));
	$.ajax({
		url: '/manager/people/roles/delete',
		type: 'POST',
		data: { uuid: uuid, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || !response.ok) {
				peopleRoleStatus((response && response.error) || peopleT('Could not delete the role.'));
				return;
			}
			row.remove();
			peopleRoleStatus(peopleT('Saved.'));
		},
		error: function() {
			peopleRoleStatus(peopleT('Could not delete the role.'));
		}
	});
});

// The person's card is fetched fresh each time it opens, so the ticks it shows
// are the roles the person holds right now. Saving writes the set as a whole.
$(document).on('click', '.people_person_role_save', function() {
	var block = $(this).closest('[data-person-uuid]');
	var status = block.find('.people_person_role_status');
	var uuid = block.attr('data-person-uuid') || '';
	var roles = [];
	block.find('.people_person_role_key:checked').each(function() {
		roles.push($(this).val());
	});
	if (!uuid) {
		status.text(peopleT('Could not save the roles.'));
		return;
	}
	status.text(peopleT('Saving…'));
	$.ajax({
		url: '/manager/people/person/roles',
		type: 'POST',
		data: { uuid: uuid, roles: JSON.stringify(roles), timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) { status.text(peopleT('Saved.')); }
			else { status.text((response && response.error) || peopleT('Could not save the roles.')); }
		},
		error: function() {
			status.text(peopleT('Could not save the roles.'));
		}
	});
});
