// The Relational workspace. One board: every construct on the left, the chosen
// construct in the middle with one drop group per social type, and a trash for
// removing a link. The old two-pane matcher is gone; the server hands over the
// whole workspace as JSON and this file draws it.
//
// Adding is deliberately possible two ways: drag a card onto a group (a desk),
// or press the + on a card (a phone, where HTML drag is unreliable). Removing
// is the x on a member, or a drag to the trash.

var relationalState = { focus: '', activeType: 'people', search: '', data: null };

function relationalOpener(focus) {
	relationalState.focus = focus || '';
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/relational',
		type: 'GET',
		data: { window_maker: 'yes', focus: focus || '', timestamp: timestamp },
		success: function(response) {
			relationalInit(response);
		}
	});
}

function relationalInit(response) {
	if (typeof response != 'object') {
		windowMaker(response);
		setTimeout(function() {
			var shell = $('#relational_workspace');
			if (shell.length) { relationalWorkspaceOpen(shell.attr('data-focus') || ''); }
		}, 80);
		return;
	}
	if (response && response.relationalizer && response.relationalizer.contents) {
		windowMaker(response.relationalizer.contents);
		setTimeout(function() {
			var shell = $('#relational_workspace');
			if (shell.length) { relationalWorkspaceOpen(shell.attr('data-focus') || ''); }
		}, 80);
		return;
	}
	if (response && response.ok && response.types) { relationalRender(response); }
}

function relationalWorkspaceOpen(focus) {
	var shell = $('#relational_workspace');
	if (!shell.length) { return; }
	relationalState.focus = focus || '';
	shell.html('<div class="relational_loading">' + relationalT('Loading…') + '</div>');
	$.ajax({
		url: '/manager/relational/workspace',
		type: 'GET',
		data: { focus: focus || '', timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.ok) { relationalRender(response); }
			else { shell.html('<div class="relational_loading">' + relationalT('Could not load the workspace.') + '</div>'); }
		},
		error: function() {
			shell.html('<div class="relational_loading">' + relationalT('Could not load the workspace.') + '</div>');
		}
	});
}

function relationalT(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function relationalEsc(value) {
	return $('<div>').text(value === undefined || value === null ? '' : String(value)).html()
		.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function relationalTypeOptions(data) {
	return (data.types || []).map(function(type) {
		return '<option value="' + relationalEsc(type.sing) + '">' + relationalEsc(type.label) + '</option>';
	}).join('');
}

function relationalCardHtml(row, type, hidden) {
	var classes = 'relational_card' + (row.app === relationalState.focus ? ' focus' : '');
	return '<div class="' + classes + '" draggable="true" data-app="' + relationalEsc(row.app) + '" data-type="' + relationalEsc(type.name) + '" data-sing="' + relationalEsc(type.sing) + '"' + (hidden ? ' style="display:none"' : '') + '>'
		+ '<span class="relational_dot" style="background:' + relationalEsc(row.colour || '#9e9e9e') + '"></span>'
		+ '<span class="relational_card_name" data-focus="' + relationalEsc(row.app) + '" title="' + relationalEsc(row.name) + '">' + relationalEsc(row.name) + '</span>'
		+ '<span class="relational_card_type">' + relationalEsc(type.label) + '</span>'
		+ '<button class="relational_card_add" data-app="' + relationalEsc(row.app) + '" data-type="' + relationalEsc(type.name) + '" title="' + relationalEsc(relationalT('Add to the focused construct')) + '">+</button>'
		+ '</div>';
}

function relationalLibraryHtml(data) {
	var tabs = (data.types || []).map(function(type) {
		var active = (type.name === relationalState.activeType) ? ' active' : '';
		return '<button class="relational_type_tab' + active + '" data-type="' + relationalEsc(type.name) + '" data-sing="' + relationalEsc(type.sing) + '">'
			+ relationalEsc(type.label) + ' <span class="relational_count">' + type.count + '</span></button>';
	}).join('');
	var cards = [];
	(data.types || []).forEach(function(type) {
		(type.rows || []).forEach(function(row) {
			cards.push(relationalCardHtml(row, type, type.name !== relationalState.activeType));
		});
	});
	return '<aside class="relational_library">'
		+ '<div class="relational_library_title">' + relationalEsc(data.labels.library) + '</div>'
		+ '<input id="relational_search" class="relational_search_input" placeholder="' + relationalEsc(data.labels.search) + '" value="' + relationalEsc(relationalState.search) + '">'
		+ '<div class="relational_type_tabs">' + tabs + '</div>'
		+ '<div class="relational_add_row">'
		+ '<input id="relational_add_name" class="relational_add_name" placeholder="' + relationalEsc(data.labels.add_placeholder) + '">'
		+ '<select id="relational_add_type" class="relational_add_type">' + relationalTypeOptions(data) + '</select>'
		+ '<button id="relational_add_button" class="relational_add_button">' + relationalEsc(data.labels.add) + '</button>'
		+ '</div>'
		+ '<div class="relational_cards">' + cards.join('') + '</div>'
		+ '</aside>';
}

function relationalMemberHtml(member) {
	return '<div class="relational_member" draggable="true" data-app="' + relationalEsc(member.app) + '" data-type="' + relationalEsc(member.type) + '" data-sing="' + relationalEsc(member.sing) + '">'
		+ '<span class="relational_dot" style="background:' + relationalEsc(member.colour || '#9e9e9e') + '"></span>'
		+ '<span class="relational_member_name" data-focus="' + relationalEsc(member.app) + '" title="' + relationalEsc(member.name) + '">' + relationalEsc(member.name) + '</span>'
		+ '<button class="relational_member_remove" data-app="' + relationalEsc(member.app) + '" data-type="' + relationalEsc(member.type) + '" title="' + relationalEsc(relationalT('Remove')) + '">&times;</button>'
		+ '</div>';
}

function relationalBoardHtml(data) {
	if (!data.focus) { return relationalOverviewHtml(data); }
	var focus = data.focus;
	var portrait = focus.image
		? '<img src="' + relationalEsc(focus.image) + '" alt="">'
		: '<span class="relational_initial" style="background:' + relationalEsc(focus.colour || '#9e9e9e') + '">' + relationalEsc((focus.name || '?').slice(0, 1).toUpperCase()) + '</span>';
	var details = '<div class="relational_details" style="display:none">'
		+ '<label>POS <select class="relational_pos">' + relationalPosOptions(data, focus.pos) + '</select></label>'
		+ '<label>MAB <select class="relational_mab">' + relationalMabOptions(data, focus.mab) + '</select></label>'
		+ '</div>';
	var columns = (data.types || []).filter(function(type) {
		return !data.focus || !data.focus.type || type.name !== data.focus.type;
	}).map(function(type) {
		var list = (data.memberships && data.memberships[type.name]) || [];
		var members = list.length ? list.map(relationalMemberHtml).join('') : '<div class="relational_empty">' + relationalEsc(data.labels.empty_members) + '</div>';
		return '<section class="relational_column" data-type="' + relationalEsc(type.name) + '" data-sing="' + relationalEsc(type.sing) + '">'
			+ '<div class="relational_column_head"><span>' + relationalEsc(type.label) + '</span><span class="relational_count">' + list.length + '</span></div>'
			+ '<div class="relational_dropzone" data-type="' + relationalEsc(type.name) + '" data-sing="' + relationalEsc(type.sing) + '">' + members + '</div>'
			+ '</section>';
	}).join('');
	return '<main class="relational_board">'
		+ '<div class="relational_focus_card">'
		+ '<div class="relational_focus_portrait">' + portrait + '</div>'
		+ '<div class="relational_focus_meta">'
		+ '<div class="relational_focus_type">' + relationalEsc(focus.type_label || '') + '</div>'
		+ '<h2>' + relationalEsc(focus.name) + '</h2>'
		+ '<div class="relational_focus_app">' + relationalEsc(focus.app) + '</div>'
		+ '<div class="relational_focus_actions">'
		+ '<button class="relational_details_toggle">' + relationalEsc(data.labels.details) + '</button>'
		+ (focus.people_uuid ? '<button class="relational_focus_people" data-uuid="' + relationalEsc(focus.people_uuid) + '">' + relationalEsc(data.labels.open_people) + '</button>' : '')
		+ '</div>'
		+ details
		+ '</div>'
		+ '<div class="relational_trash">' + relationalEsc(data.labels.drop_to_remove) + '</div>'
		+ '</div>'
		+ '<p class="relational_hint">' + relationalEsc(data.labels.focus_hint) + '</p>'
		+ '<div class="relational_columns">' + columns + '</div>'
		+ '</main>';
}

function relationalPosOptions(data, current) {
	return (data.pos_options || []).map(function(option) {
		return '<option value="' + relationalEsc(option.value) + '"' + (option.value === current ? ' selected' : '') + '>' + relationalEsc(option.label) + '</option>';
	}).join('');
}

function relationalMabOptions(data, current) {
	var blank = '<option value=""' + (!current ? ' selected' : '') + '></option>';
	return blank + (data.pos_options || []).map(function(option) {
		return '<option value="' + relationalEsc(option.value) + '"' + (option.value === current ? ' selected' : '') + '>' + relationalEsc(option.label) + '</option>';
	}).join('');
}

function relationalOverviewHtml(data) {
	var cards = (data.types || []).map(function(type) {
		var names = (type.rows || []).slice(0, 6).map(function(row) {
			return '<span class="relational_overview_name" data-focus="' + relationalEsc(row.app) + '">' + relationalEsc(row.name) + '</span>';
		}).join('');
		return '<div class="relational_overview_card" data-type="' + relationalEsc(type.name) + '">'
			+ '<h3>' + relationalEsc(type.label) + '</h3>'
			+ '<div class="relational_overview_count">' + type.count + '</div>'
			+ '<div class="relational_overview_names">' + names + '</div>'
			+ '</div>';
	}).join('');
	return '<main class="relational_board relational_overview">'
		+ '<h2>' + relationalEsc(data.labels.all_constructs) + '</h2>'
		+ '<p class="relational_hint">' + relationalEsc(data.labels.overview) + '</p>'
		+ '<div class="relational_overview_grid">' + cards + '</div>'
		+ '</main>';
}

function relationalRender(data) {
	relationalState.data = data;
	if (!relationalState.activeType || !(data.types || []).some(function(type) { return type.name === relationalState.activeType; })) {
		relationalState.activeType = (data.types && data.types.length) ? data.types[0].name : 'people';
	}
	var shell = $('#relational_workspace');
	shell.html('<div class="relational_shell">' + relationalLibraryHtml(data) + relationalBoardHtml(data) + '</div>');
	$('#relational_add_type').val(relationalCurrentSing());
	relationalApplyFilter();
	var active = $('#relational_workspace .relational_type_tab.active')[0];
	if (active && active.scrollIntoView) { active.scrollIntoView({ inline: 'nearest', block: 'nearest' }); }
}

function relationalCurrentSing() {
	var types = (relationalState.data && relationalState.data.types) || [];
	for (var i = 0; i < types.length; i++) {
		if (types[i].name === relationalState.activeType) { return types[i].sing; }
	}
	return '';
}

function relationalApplyFilter() {
	var search = ($('#relational_search').val() || '').toLowerCase();
	$('#relational_workspace .relational_card').each(function() {
		var card = $(this);
		var matches = card.attr('data-type') === relationalState.activeType
			&& (!search || card.find('.relational_card_name').text().toLowerCase().indexOf(search) !== -1);
		card.toggle(matches);
	});
}

function relationalLink(member, type, movement) {
	if (!relationalState.focus) {
		relationalWorkspaceToast(relationalT('Focus a construct first.'));
		return;
	}
	$.ajax({
		url: '/manager/relational/link',
		type: 'POST',
		data: {
			focus: relationalState.focus,
			member: member,
			type: type,
			movement: movement || 'add',
			timestamp: Date.now()
		},
		dataType: 'json',
		success: function(response) {
			if (response && response.ok && response.types) { relationalRender(response); }
			else { relationalWorkspaceToast(relationalT('Could not save that link.')); }
		},
		error: function() { relationalWorkspaceToast(relationalT('Could not save that link.')); }
	});
}

function relationalWorkspaceToast(text) {
	var toast = $('#relational_toast');
	if (!toast.length) {
		toast = $('<div id="relational_toast" class="relational_toast"></div>').appendTo('#relational_workspace');
	}
	toast.text(text).show();
	clearTimeout(toast.data('timer'));
	toast.data('timer', setTimeout(function() { toast.fadeOut(200); }, 2200));
}

$(document).on('click', '#relational_toggle', function() {
	relationalOpener('');
});

$(document).on('click', '.relational_type_tab', function() {
	relationalState.activeType = $(this).attr('data-type');
	$('#relational_workspace .relational_type_tab').removeClass('active');
	$(this).addClass('active');
	$('#relational_add_type').val($(this).attr('data-sing'));
	relationalApplyFilter();
});

$(document).on('input', '#relational_search', function() {
	relationalState.search = $(this).val() || '';
	relationalApplyFilter();
});

$(document).on('click keypress', '.relational_card_name', function(e) {
	if (e.type === 'keypress' && e.keyCode !== 13) { return; }
	var focus = $(this).attr('data-focus');
	if (focus) { relationalWorkspaceOpen(focus); }
});

$(document).on('click', '.relational_member_name', function() {
	var focus = $(this).attr('data-focus');
	if (focus) { relationalWorkspaceOpen(focus); }
});

$(document).on('click', '.relational_card_add', function(e) {
	e.stopPropagation();
	var app = $(this).attr('data-app');
	var type = $(this).attr('data-type');
	if (!relationalState.focus) {
		relationalWorkspaceOpen(app);
		return;
	}
	relationalLink(app, type, 'add');
});

$(document).on('click', '.relational_member_remove', function(e) {
	e.stopPropagation();
	relationalLink($(this).attr('data-app'), $(this).attr('data-type'), 'delete');
});

$(document).on('click', '.relational_details_toggle', function() {
	$(this).closest('.relational_focus_card').find('.relational_details').toggle();
});

$(document).on('change', '.relational_pos, .relational_mab', function() {
	var setting = $(this).hasClass('relational_pos') ? 'pos' : 'mab';
	var value = $(this).val();
	if (!relationalState.focus) { return; }
	$.ajax({
		url: '/manager/setting_setter',
		type: 'POST',
		data: { app: relationalState.focus, setting: setting, value: value, timestamp: Date.now() },
		success: function() { relationalWorkspaceOpen(relationalState.focus); },
		error: function() { relationalWorkspaceToast(relationalT('Could not save that change.')); }
	});
});

$(document).on('click', '.relational_focus_people', function() {
	var uuid = $(this).attr('data-uuid');
	if (uuid && typeof peopleOpener === 'function') {
		peopleOpener();
		setTimeout(function() { if (typeof peoplePersonOpen === 'function') { peoplePersonOpen(uuid); } }, 400);
	}
});

$(document).on('click', '.relational_add_button', function() {
	var name = ($('#relational_add_name').val() || '').trim();
	var construct = $('#relational_add_type').val() || '';
	if (!name || !construct) { relationalWorkspaceToast(relationalT('Type a name first.')); return; }
	$.ajax({
		url: '/manager/relational/adder',
		type: 'POST',
		data: { construct: construct, addition: name, timestamp: Date.now() },
		success: function() {
			$('#relational_add_name').val('');
			relationalWorkspaceOpen(relationalState.focus);
		},
		error: function() { relationalWorkspaceToast(relationalT('Could not add that construct.')); }
	});
});

$(document).on('keypress', '#relational_add_name', function(e) {
	if (e.keyCode === 13) { $('.relational_add_button').trigger('click'); }
});

$(document).on('dragstart', '.relational_card, .relational_member', function(e) {
	var data = {
		app: $(this).attr('data-app'),
		type: $(this).attr('data-type'),
		sing: $(this).attr('data-sing'),
		member: $(this).hasClass('relational_member') ? 1 : 0
	};
	e.originalEvent.dataTransfer.setData('text/plain', JSON.stringify(data));
	e.originalEvent.dataTransfer.effectAllowed = 'copyMove';
	$(this).addClass('relational_dragging');
});

$(document).on('dragend', '.relational_card, .relational_member', function() {
	$(this).removeClass('relational_dragging');
	$('#relational_workspace .relational_drop_active').removeClass('relational_drop_active');
});

$(document).on('dragover', '.relational_dropzone, .relational_trash', function(e) {
	e.preventDefault();
	e.originalEvent.dataTransfer.dropEffect = 'copy';
	$(this).addClass('relational_drop_active');
});

$(document).on('dragleave', '.relational_dropzone, .relational_trash', function() {
	$(this).removeClass('relational_drop_active');
});

$(document).on('drop', '.relational_dropzone, .relational_trash', function(e) {
	e.preventDefault();
	$(this).removeClass('relational_drop_active');
	var raw = e.originalEvent.dataTransfer.getData('text/plain');
	var data;
	try { data = JSON.parse(raw); } catch (error) { return; }
	if (!data || !data.app) { return; }
	if ($(this).hasClass('relational_trash')) {
		if (data.member) { relationalLink(data.app, data.type, 'delete'); }
		return;
	}
	if (data.member) { return; }
	var type = $(this).attr('data-type');
	if (data.type !== type) {
		relationalWorkspaceToast(relationalT('Drop it on its own group.'));
		return;
	}
	relationalLink(data.app, type, 'add');
});

$(document).on('click', '.relational_overview_card h3, .relational_overview_name', function() {
	var name = $(this).hasClass('relational_overview_name') ? $(this).attr('data-focus') : '';
	if (name) { relationalWorkspaceOpen(name); return; }
	var type = $(this).closest('.relational_overview_card').attr('data-type');
	if (type) {
		relationalState.activeType = type;
		$('#relational_workspace .relational_type_tab[data-type="' + type + '"]').trigger('click');
	}
});
