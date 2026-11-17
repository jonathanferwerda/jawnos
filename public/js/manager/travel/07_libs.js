// ---- installing a view's library ----------------------------------------
// Three views need a library the tree does not ship: Cesium for the globe,
// MapLibre and PMTiles for the street map and the world, A-Frame for the world
// itself. Their notes used to name a terminal command, which a phone cannot
// run. The note now carries an Install button: it asks the house, which runs
// that script on this machine (scripts/fetch_*.sh) and answers with the last
// lines it printed. The view is opened again afterwards and the library is
// there; nothing is fetched from a third-party origin at draw time.
function travelLibInstall(lib, button) {
	var el = $(button);
	el.prop('disabled', true).text(jawnosT('Installing\u2026'));
	$.ajax({
		url: '/manager/travel/libs_install',
		type: 'POST',
		dataType: 'json',
		data: { what: lib },
		// a few megabytes over a phone's connection may take a minute
		timeout: 300000
	}).done(function (r) {
		if (r && r.ok) {
			el.text(jawnosT('Installed - open it again'));
			return;
		}
		el.prop('disabled', false).text(jawnosT('Install'));
		var why = (r && (r.error || r.output)) || '';
		if (why) { el.attr('title', String(why).slice(0, 300)); }
	}).fail(function () {
		el.prop('disabled', false).text(jawnosT('Install'));
	});
}

// The button a note carries beside the words that named the command.
function travelLibInstallButton(note, lib) {
	return $('<button type="button"></button>')
		.attr('style', 'margin-left:8px;padding:2px 10px;font:inherit;border-radius:6px;'
			+ 'border:1px solid currentColor;background:transparent;color:inherit;cursor:var(--jawnos-cursor-pointer, pointer);')
		.text(jawnosT('Install'))
		.on('click', function () { travelLibInstall(lib, this); })
		.appendTo(note);
}
