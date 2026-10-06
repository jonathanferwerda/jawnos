var headerHeight = 50;
function headerPrinter(ctx,appts,title) {
	ctx.fillStyle = 'yellow';
	ctx.font = "400 24px arial";
	var canvas = document.getElementById(title.toLowerCase());
	$('#' + title.toLowerCase()).show();
	ctx.fillStyle = 'black';
	var sorts = localStorage.getItem('sorts');
	var scope = localStorage.getItem('scope');

	var formatted_time = fixedTimeString(numeral(appts['__specs']['timestamp']).value());
	var header = format_name(scope) + '<br>' + formatted_time;
	if (!windowPhoneChecker()) {
		header = header + ' ' + appts['__specs']['birthday'];
	}
	$('#header').html(header);
	if (formatted_time.match('NaN')) {
	//	formatted_time = appts['__specs']['formatted_timestamp'];
	}
//	ctx.fillText(formatted_time + '  ' + appts['__specs']['birthday'], 5  , 65 );
	ctx.font = "400 28px Arial";
	ctx.save('init');

	if (appts['__stash']) {
	/*
		ctx.save('stash');
		ctx.fillStyle = 'black';
		ctx.fillRect(-10, canvas.height * .98, canvas.width, canvas.height * .98);
		ctx.fillStyle = 'black';
		var vertical = 105;
		ctx.fillText('d: ' + numeral(appts['__stash']['day_total_' + sorts]).format('0,0.00'), 5 , vertical );
		ctx.fillText('w: ' + numeral(appts['__stash']['week_total_' + sorts]).format('0,0.00'), 5 + 160 , vertical );
		ctx.fillText('m: ' + numeral(appts['__stash']['month_total_' + sorts]).format('0,0.00'), 5 + 310 , vertical );
		ctx.fillText('y: ' + numeral(appts['__stash']['year_total_' + sorts]).format('0,0.00'), 5 + 460 , vertical );
		ctx.restore('stash')
		*/
	}
	ctx.beginPath();
	ctx.strokeStyle = 'yellow';
	reservedSpots['header'] = headerHeight - 4;
	ctx.lineWidth = 10;
	ctx.moveTo(0, headerHeight);
	reservedSpots['header']['y'] = headerHeight;
	ctx.fill();
	ctx.stroke();
	//ctx.fillText(scope, 5, 30);

	ctx.fill();
}


var appPosition;
function leaderboardPrinter(appts) {
	appPosition = [];
	var lineHeight = 26;
	var scope = localStorage.getItem('scope');
	var sorts = localStorage.getItem('sorts');
	var filter = scope + '_' + sorts;
	$('#leaderboard').show();
	var canvas = document.getElementById('leaderboard');
	canvas.width = $('#background').width();
	var translateHeight = 0;
	
	var temp_height = (canvas.height * .10);
	$.each(appts,function(i,v) {
		if (!v.list) { return true; }
		temp_height = (temp_height + (numeral(lineHeight)).value());
	});

	if (temp_height > $(window).height()) {
		$('#leaderboard').height(temp_height);
		canvas.height = temp_height;
	}
	else {
		canvas.height = $(window).height();
		$('#leaderboard').height(canvas.height);
	}

	ctx = canvas.getContext('2d');


	var outer = canvas.height;

	headerPrinter(ctx,appts,'Leaderboard');
	ctx.save('leaderboard');

	var lineWidth = 2500;
	var warrantyHeight = 55;
	var startingHeight = 100 + clothesLineHeight;
	ctx.translate(7, startingHeight);
	var appt_storage = [];

	$.each(appts, function(appt_n,appt) {
		if (appts[appt_n][filter]) {
			var appt_check = $.grep(appt_storage, function(n,i) { return (n.formatted_name == appt.formatted_name) })
			if (appt_check.length == 0 ) {
				appt.setting.colour = appts[appt_n].setting.colour;
				appt_storage.push(appt);
			}
		}
	});
	var appt_store = appt_storage.sort((a, b) => b[filter] - a[filter] );
	var rightNow = appts.timestamp;
	var presently = Date.now();
	var nowWatch;
	var dateWatch;
	ctx.font = "420 " + lineHeight + "px Arial";


	for (i = 0; i <= appt_store.length; i++) {
		if (appt_store[i] == undefined) { continue; }
		if (appt_store[i]['timestamp'] < presently && nowWatch != 'completed') {
//			ctx.fillStyle = 'black';
				ctx.beginPath();
				ctx.fillStyle = appt_store[i].setting.colour || 'black';
				ctx.strokeStyle = 'black';
				ctx.globalAlpha = 1;
				ctx.arc(canvas.width - 17, 0, 33, (Math.PI * 2),.5, true);
				ctx.fill();
	//			ctx.fillText(new_arr[i].name,0,0);
				ctx.arc(canvas.width - 17, 0, 31, (Math.PI * 2),.5, true);
				ctx.stroke();
				nowWatch = 'completed';

		}


		if (appt_store[i] != undefined) {
			var point = appt_store[i][filter];
			ctx.fillStyle = appt_store[i].setting.colour || 'black';
			ctx.save('u');
			if (appt_store[i].setting.status == 'record') {
				ctx.globalAlpha = 1;
				ctx.fillRect(-10, 0, canvas.width, lineHeight * 1.1);
				ctx.fillStyle = 'black';
			}
			else if (appt_store[i].setting.status == 'start') {
				ctx.globalAlpha = 1;
				ctx.fillRect(-10, 0, canvas.width, lineHeight * 1.1);
				ctx.fillStyle = 'black';
			}
			else if (appt_store[i].setting.status == 'pause') {
				ctx.globalAlpha = 1;
				ctx.fillRect(30, 0, $('#background').width() - 330, lineHeight * 1.1);
				ctx.fillStyle = 'black';
			}
			else {
				ctx.globalAlpha = 0.03
				ctx.fillRect(-10, 0, canvas.width, lineHeight * 1.1);
			}
			ctx.globalAlpha = 1;
			ctx.translate(0, lineHeight);
			ctx.save('y');
			ctx.translate(-2,0);
			ctx.fillText(appt_store[i].shorthand_name, 0, 0);

			ctx.translate(85,0);
			ctx.fillText(appt_store[i]['just_time'], 0, 0);
			ctx.translate(120,0);
			ctx.fillText(appt_store[i][scope + '_occurrences'], 0, 0);
			appPosition.push([0, (lineHeight * i) + startingHeight, lineWidth, ((lineHeight * i) + (lineHeight)) + startingHeight, appt_store[i]]);
			ctx.translate(40,0);
			ctx.fillText(appt_store[i]['formatted_since'], 0, 0);
			ctx.translate(140,0);

			ctx.fillText(appt_store[i][scope + '_formatted_duration'], 0, 0);


		//	ctx.fillText(appt_store[i][scope + '_duration_percent'], 0,0);
			point =  appt_store[i][scope + '_timestamp'];
//ctx.fillText(point, 0, 0);

			if (appt_store[i][scope + '_amount']) {
				ctx.fillText('$' + appt_store[i][scope + '_amount'], 110, 0);
				ctx.translate(120,0);
				if (appt_store[i][scope + '_tax']) {
					ctx.fillText('$' + appt_store[i][scope + '_tax'], 110, 0);
				}
				ctx.translate(120,0);
				ctx.fillText('$' + appt_store[i][scope + '_total'], 110, 0);
				ctx.translate(120,0);
				ctx.fillText((numeral(appt_store[i][scope + '_percent']).format(".2f") * 100) + '%', 110, 0);
			}
			translateHeight = (lineHeight * i) + startingHeight + lineHeight;

			ctx.restore('y');
		}


	}
	ctx.translate(0,( -1 * translateHeight));

	ctx.closePath();
}

$(document).on('click', '.background', function (e) {
	var scroll = $(document).scrollTop();
	var x = e.clientX - numeral($(this).css('left')).value();
	var y = (e.clientY + scroll);


	var printer = localStorage.getItem('layout');
	var app_clicked = 0;
	ctx.save('click');
	ctx.moveTo(0,0);
	clearInterval(clothesLinePos['smoothScrolling']);
	clearInterval(clothesLinePos['timelineSmoothScrolling']);
	$.each(appPosition, function(i,o) {
		if (o[0] < x && o[2] > x &&
					o[1] < y && o[3] > y) {
			app_clicked = 1;
			var app = JSON.stringify(o[4]);
			var timestamp = Date.now();
			var canvas = document.getElementById(printer);
			var ctx = canvas.getContext('2d');
			ctx.fillStyle = 'black';
			ctx.strokeStyle = 'black';
			ctx.globalAlpha = 1;

			// at the point
			var count = 0;

			var move = setInterval(function(resp) {

				ctx.arc(x, y, 0, count, (Math.PI*2), true);
				ctx.stroke();
			//	ctx.fill();


				if (count > 45) {
					ctx.restore('click');
					clearInterval(move);
				}
				count++;
			},13);
			var sapp = JSON.stringify({ 'name': o[4]['name'] });
			appointmentGrabber(o[4]['name'],timestamp);

			return false;
		}
	});
	if (app_clicked == 0 && device == 'mobile') {
		var ph = $('#pseudonym_home').offset();
		pseudonymHomeShower(ph.left + 3, ph.top + 3);
	}

	$('.search_results').hide();

});

$(document).on('dblclick', '.background', function() {
	$('#now_toggle').trigger('click');
});

$(document).on('mousemove', '.background', function(e) {
	var scroll = $(document).scrollTop();
	var x = e.clientX - numeral($(this).css('left')).value();
	var y = (e.clientY + scroll);
	var hovering = 0;
	$.each(appPosition, function(i,o) {
		if (o[0] < x && o[2] > x &&
			o[1] < y && o[3] > y) {
			hovering = 1;
		}
	});
	if (hovering == 1) {
		$('.background').css({'cursor': 'pointer'});
	}
	else {
		$('.background').css({'cursor': 'auto'});
	}
});