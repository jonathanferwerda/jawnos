// The Intelligence app: the house's AI token ledger, read-only except for the
// evaluation cadence and weekdays, as five pills in one window - Overview,
// Agents, Evaluations, Providers and History. The server draws every panel and
// every History range in the one request; this script swaps what is shown,
// filters the evaluation rows, remembers the pill and range a person left, and
// sends a frequency or weekday change through the app's one cadence route.
var intelligenceSectionKey = 'intelligence_section';
var intelligenceSectionDefault = 'overview';
var intelligenceHistoryKey = 'intelligence_history_range';
var intelligenceHistoryDefault = '7d';

$(document).on('click', '#intelligence_toggle, .intelligence_toggle', function() {
	intelligenceOpener();
});

function intelligenceOpener(timestamp) {
	if (!timestamp) { timestamp = Date.now(); }
	$.ajax({
		url: '/manager/intelligence',
		type: 'GET',
		data: { timestamp: timestamp, user_agent: navigator.userAgent },
		success: function(response) {
			if (!response) { return; }
			windowMaker(response.window || response);
			intelligenceRestore();
		}
	});
}

// --- the section pills -------------------------------------------------------
// One section at a time, scrolled sideways on a narrow window rather than
// wrapped, and the section left is remembered in this browser.
function intelligenceSectionNames() {
	var names = [];
	$('#intelligence .intelligence_section_pill').each(function() {
		var name = $(this).attr('data-section');
		if (name) { names.push(name); }
	});
	return names;
}

function intelligenceSectionShow(name, remember) {
	var names = intelligenceSectionNames();
	if (!names.length) { return; }
	if ($.inArray(name, names) < 0) { name = intelligenceSectionDefault; }
	if ($.inArray(name, names) < 0) { name = names[0]; }
	$('#intelligence .intelligence_section_pill').each(function() {
		var on = $(this).attr('data-section') == name;
		$(this).toggleClass('is-active', on).attr('aria-selected', on ? 'true' : 'false');
	});
	$('#intelligence .intelligence_section').each(function() {
		var on = $(this).attr('data-section') == name;
		$(this).toggleClass('is-active', on).prop('hidden', !on);
	});
	if (remember) {
		try { localStorage.setItem(intelligenceSectionKey, name); } catch (e) {}
	}
}

function intelligenceSectionRestore() {
	var name = '';
	try { name = localStorage.getItem(intelligenceSectionKey) || ''; } catch (e) { name = ''; }
	intelligenceSectionShow(name, false);
}

// --- the History ranges ------------------------------------------------------
function intelligenceHistoryNames() {
	var names = [];
	$('#intelligence .intelligence_filter_pill[data-history-range]').each(function() {
		var name = $(this).attr('data-history-range');
		if (name) { names.push(name); }
	});
	return names;
}

function intelligenceHistoryShow(range, remember) {
	var names = intelligenceHistoryNames();
	if (!names.length) { return; }
	if ($.inArray(range, names) < 0) { range = intelligenceHistoryDefault; }
	if ($.inArray(range, names) < 0) { range = names[0]; }
	$('#intelligence .intelligence_filter_pill[data-history-range]').each(function() {
		$(this).toggleClass('is-active', $(this).attr('data-history-range') == range);
	});
	$('#intelligence .intelligence_history_panel').each(function() {
		$(this).toggleClass('is-active', $(this).attr('data-history-range-panel') == range);
	});
	if (remember) {
		try { localStorage.setItem(intelligenceHistoryKey, range); } catch (e) {}
	}
}

function intelligenceHistoryRestore() {
	var range = '';
	try { range = localStorage.getItem(intelligenceHistoryKey) || ''; } catch (e) { range = ''; }
	intelligenceHistoryShow(range, false);
}

// --- the evaluation filter ---------------------------------------------------
// Each scope wears one state; a pill shows only the rows of that state, while
// All shows every row.
function intelligenceEvalFilter(state) {
	if (!state) { state = 'all'; }
	$('#intelligence .intelligence_filter_pill[data-eval-filter]').each(function() {
		$(this).toggleClass('is-active', $(this).attr('data-eval-filter') == state);
	});
	$('#intelligence tr[data-eval-state]').each(function() {
		$(this).toggle(state == 'all' || $(this).attr('data-eval-state') == state);
	});
}

// --- changing a scope's frequency -------------------------------------------
// The cadence setting, the weekdays and the Minion schedule are one thing: the
// route saves any weekdays in the same request and calls evaluation_cadence_apply,
// then answers with what now exists, not what was asked for.
function intelligenceNote(text) {
	var note = $('#intelligence .intelligence_note').first();
	if (!note.length) { return; }
	note.text(text || '');
}

function intelligenceCadenceSave(scope, cadence, days) {
	if (!scope) { return; }
	intelligenceNote('');
	var payload = { app: scope, cadence: cadence };
	if (typeof days !== 'undefined') { payload.days = days; }
	$.ajax({
		url: '/manager/intelligence/cadence',
		type: 'POST',
		dataType: 'json',
		data: payload,
		success: function(response) {
			var row = $('#intelligence .intelligence_cadence').filter(function() {
				return $(this).attr('data-scope') === scope;
			}).first().closest('tr');
			if (response && typeof response.days !== 'undefined') {
				var keep = String(response.days).split(',').filter(function(v) { return v !== '' && v !== 'none'; });
				row.find('.intelligence_day').each(function() {
					var on = keep.indexOf(String($(this).attr('data-day'))) >= 0;
					$(this).toggleClass('is-on', on).attr('aria-pressed', on ? 'true' : 'false');
				});
			}
			if (response && (response.ok === 0 || response.ok === 'no')) {
				if (response.cadence) { row.find('.intelligence_cadence').val(response.cadence); }
				intelligenceNote(response.error || jawnosT('Could not change the evaluation frequency.'));
				return;
			}
			var now = (response && response.cadence) ? response.cadence : cadence;
			row.find('.intelligence_cadence').val(now);
			var daysOn = (now === 'daily' || now === 'weekly');
			row.find('.intelligence_day').prop('disabled', !daysOn);
			// The weekday picker is only a second control when it applies: an off,
			// hourly or monthly scope cannot have weekdays, so its cell stays hidden.
			row.find('.intelligence_days_cell').prop('hidden', !daysOn);
			var next = row.find('.intelligence_next_run').first();
			if (response && response.next_run) {
				next.text(new Date(response.next_run * 1000).toLocaleString());
			}
			else {
				next.text('—');
			}
			var state = (now === 'off') ? 'idle' : ((now === 'each_run') ? 'on_demand' : 'scheduled');
			row.attr('data-eval-state', state);
			var active = $('#intelligence .intelligence_filter_pill[data-eval-filter].is-active').attr('data-eval-filter') || 'all';
			intelligenceEvalFilter(active);
		},
		error: function() {
			intelligenceNote(jawnosT('Could not change the evaluation frequency.'));
		}
	});
}

$(document).on('change', '#intelligence .intelligence_cadence', function() {
	var pick = $(this);
	intelligenceCadenceSave(pick.attr('data-scope'), pick.val());
});

// Each day is a toggle, not a second dropdown: pressing one sends the whole
// set in the same cadence request, so the saved weekdays and the schedule
// stay one.
$(document).on('click', '#intelligence .intelligence_day', function() {
	var btn = $(this);
	if (btn.prop('disabled')) { return; }
	var cell = btn.closest('.intelligence_days_cell');
	var on = btn.toggleClass('is-on').hasClass('is-on');
	btn.attr('aria-pressed', on ? 'true' : 'false');
	var nights = [];
	cell.find('.intelligence_day.is-on').each(function() { nights.push($(this).attr('data-day')); });
	var value = nights.length ? nights.join(',') : 'none';
	var cadence = cell.closest('tr').find('.intelligence_cadence').val() || 'off';
	intelligenceCadenceSave(cell.attr('data-scope'), cadence, value);
});

function intelligenceRestore() {
	intelligenceSectionRestore();
	intelligenceHistoryRestore();
	intelligenceEvalFilter('all');
}

// --- provider balances in the chosen currency --------------------------------
// The Providers panel reuses Configure's currency_amount include, so each
// balance carries its house-currency figure and a picker of the loaded rates.
// Configure's own handler is only bound once that app has been opened, so the
// Intelligence window converts from the same data itself.
function intelligenceCurrencyValue(value) {
	if (!isFinite(value)) { return ''; }
	var abs = Math.abs(value);
	return (abs > 0 && abs < 0.1) ? value.toFixed(4) : value.toFixed(2);
}

$(document).on('change', '#intelligence .currency_picker', function() {
	var select = this;
	var option = select.options[select.selectedIndex];
	var rate = option ? parseFloat(option.getAttribute('data-rate')) : NaN;
	var amount = $(select).closest('.currency_amount');
	var base = parseFloat(amount.attr('data-base-amount'));
	if (!isFinite(rate) || !isFinite(base)) { return; }
	amount.find('.currency_value').text(intelligenceCurrencyValue(base * rate));
});

$(document).on('click', '#intelligence .intelligence_section_pill', function() {
	intelligenceSectionShow($(this).attr('data-section'), true);
});

$(document).on('click', '#intelligence .intelligence_filter_pill[data-history-range]', function() {
	intelligenceHistoryShow($(this).attr('data-history-range'), true);
});

$(document).on('click', '#intelligence .intelligence_filter_pill[data-eval-filter]', function() {
	intelligenceEvalFilter($(this).attr('data-eval-filter'));
});
