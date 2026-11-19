// What every layout printer and the desk's own paints share.
//
// This file stays in the core bundle. The six canvas printers (timeline,
// calendar, leaderboard, continent, clockface, narrator) load as one lazy
// chunk, but the desk draws without them: its background fallback paints the
// header and hangs the clothesline, and the rail's hit test reads appPosition.
// So the header band, its height, and the hit-area list live here, where a
// desk-only page already has them.

// The band above the clothesline is gone - the scope and the desk's birthday
// went with it - so nothing is reserved there unless a taskbar has taken the
// top edge; taskbar.js measures that and writes it back here.
var headerHeight = 0;

// The hit areas the printers push and the clothesline reads: [left, top,
// right, bottom, row]. The chunk re-initialises it when it loads, before the
// first draw; a desk page keeps this one and only ever holds clothes.
var appPosition = [];

function headerPrinter(ctx,appts,title) {
	var canvas = document.getElementById(title.toLowerCase());
	$('#' + title.toLowerCase()).show();

	var formatted_time = fixedTimeString(numeral(appts['__specs']['timestamp']).value());
	// the clock lives in the taskbar while there is one - it reads the raw
	// timestamp so a phone can wear its shorter two-line face - and the header
	// span keeps only the clock's fallback home for when that bar is set away
	var clock_in_bar = (typeof jawnosClockInTaskbar == 'function') && jawnosClockInTaskbar();
	var clock_stamp = numeral(appts['__specs']['timestamp']).value();
	var clock_stationary = (appts['__specs']['time_machine_stationary'] == 1);
	if (typeof jawnosClockAnchorSet == 'function') { jawnosClockAnchorSet(clock_stamp, clock_stationary); }
	else if (typeof jawnosClockShow == 'function') { jawnosClockShow(clock_stamp); }
	$('#header').html(clock_in_bar ? '' : formatted_time);

	// the divider under the old header text - a moveTo alone never drew a line -
	// stands only while a top taskbar has lifted the rows down. It wears a mid-tone
	// of the theme's own colour (the ink is black on a light desk), with the
	// contrasting halo beneath it over a background picture.
	if (headerHeight > 0) {
		var ink = (typeof jawnosPrinterLine == 'function') ? jawnosPrinterLine() : jawnosInk();
		var halo = typeof jawnosPrinterHalo == 'function' ? jawnosPrinterHalo() : undefined;
		ctx.save();
		ctx.beginPath();
		ctx.moveTo(0, headerHeight);
		ctx.lineTo(canvas ? canvas.width : $(window).width(), headerHeight);
		if (halo) {
			ctx.strokeStyle = halo;
			ctx.lineWidth = 14;
			ctx.stroke();
		}
		ctx.strokeStyle = ink;
		ctx.lineWidth = 10;
		ctx.stroke();
		ctx.restore();
	}
	reservedSpots['header'] = Math.max(0, headerHeight - 4);
}
