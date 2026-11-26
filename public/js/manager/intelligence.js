// The Intelligence app: the house's AI token ledger, read-only, as five pills
// in one window - Overview, Agents, Evaluations, Providers and History. The
// server draws every panel and every History range in the one request; this
// script swaps what is shown, filters the evaluation rows and remembers the
// pill and range a person left, per browser. Nothing here writes.
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

function intelligenceRestore() {
	intelligenceSectionRestore();
	intelligenceHistoryRestore();
	intelligenceEvalFilter('all');
}

$(document).on('click', '#intelligence .intelligence_section_pill', function() {
	intelligenceSectionShow($(this).attr('data-section'), true);
});

$(document).on('click', '#intelligence .intelligence_filter_pill[data-history-range]', function() {
	intelligenceHistoryShow($(this).attr('data-history-range'), true);
});

$(document).on('click', '#intelligence .intelligence_filter_pill[data-eval-filter]', function() {
	intelligenceEvalFilter($(this).attr('data-eval-filter'));
});
