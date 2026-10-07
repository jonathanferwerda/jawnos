var ap;

function appointmentEventMaker(appts,sort) {
	var appointment_events = { day: [], hour: [], week: [], month: [], year: [], decade: [], century: [], millenium: [], age: [] };
	$('#clockface').show();
	$.each(appts, function(i,v) {
		$.each(['list','transactions'],function(n,val) {
			var size = val.length;
			$.each(v[val],function(numero,value) {
				if (value.age_percent) {
					var minute = numeral(60 * (value.age_percent)).format('0');
					var hour = moment(numeral(value.timestamp).value()).format('h');
						appointment_events.age.push({
							'minute': minute,
							'timestamp': value.timestamp, 
							'value': value,
							size: size,
							colour: v.setting.colour,
							name: v.formatted_name
						});
				}
				if (value.millenium_percent) {
					var minute = numeral(60 * (value.millenium_percent)).format('0');
					var hour = moment(numeral(value.timestamp).value()).format('h');
						appointment_events.decade.push({
							'minute': minute,
							'timestamp': value.timestamp, 
							'value': value,
							size: size,
							colour: v.setting.colour,
							name: v.formatted_name
						});
				}
				if (value.decade_percent) {
					var minute = numeral(60 * (value.decade_percent)).format('0');
					var hour = moment(numeral(value.timestamp).value()).format('h');
						appointment_events.decade.push({
							'minute': minute,
							'timestamp': value.timestamp, 
							'value': value,
							size: size,
							colour: v.setting.colour,
							name: v.formatted_name
						});
				}
				if (value.year_percent) {
					var minute = numeral(60 * (value.year_percent)).format('0');
					var hour = moment(numeral(value.timestamp).value()).format('h');
						appointment_events.month.push({
							'minute': minute,
							'timestamp': value.timestamp, 
							'value': value,
							size: size,
							colour: v.setting.colour,
							name: v.formatted_name
						});
				}
				if (value.month_percent) {
					var minute = numeral(60 * (value.month_percent)).format('0');
					var hour = moment(numeral(value.timestamp).value()).format('h');
						appointment_events.month.push({
							'minute': minute,
							'timestamp': value.timestamp, 
							'value': value,
							size: size,
							colour: v.setting.colour,
							name: v.formatted_name
						});
				}
				if (value.week_percent) {
					var minute = numeral(60 * (value.week_percent)).format('0');
					var hour = moment(numeral(value.timestamp).value()).format('h');
						appointment_events.week.push({
							'minute': minute,
							'timestamp': value.timestamp, 
							'value': value,
							size: size,
							colour: v.setting.colour,
							name: v.formatted_name
						});
				}
				if (value.day_percent) {
					var minute = numeral(60 * (value.day_percent)).format('0');
					var hour = moment(numeral(value.timestamp).value()).format('h');
						appointment_events.day.push({
							'minute': minute,
							'timestamp': value.timestamp, 
							'value': value,
							size: size,
							colour: v.setting.colour,
							name: v.formatted_name
						});
				}
				if (value.hour_percent) {
//					var minute = moment(numeral(value.timestamp).value()).format('m');
					var minute = numeral(60 * (value.hour_percent)).format(0);
					var hour = moment(numeral(value.timestamp).value()).format('h');
					appointment_events.hour.push({
						'minute': minute,
						'hour': hour,
						'timestamp': value.timestamp,
						'value': value,
						'size': size,
						colour: v.setting.colour,
						formatted_name: v.formatted_name
					});
				}

			});
		});
	});

//	appointment_events.age.sort((a, b) => (a[sort] > b[sort]) ? 1 : -1);
//	appointment_events.millenium.sort((a, b) => (a[sort] > b[sort]) ? 1 : -1);
//	appointment_events.century.sort((a, b) => (a[sort] > b[sort]) ? 1 : -1);
//	appointment_events.decade.sort((a, b) => (a[sort] > b[sort]) ? 1 : -1);
	appointment_events.year.sort((a, b) => (a[sort] > b[sort]) ? 1 : -1);
	appointment_events.month.sort((a, b) => (a[sort] > b[sort]) ? 1 : -1);
	appointment_events.week.sort((a, b) => (a[sort] > b[sort]) ? 1 : -1);
	appointment_events.day.sort((a, b) => (a[sort] > b[sort]) ? 1 : -1);
	appointment_events.hour.sort((a, b) => (a[sort] > b[sort]) ? 1 : -1);
	return appointment_events;
}

var lastY;
$(document).ready(function() {
	localStorage.setItem('scrollPositioner', .4);
});

var appPosition;
function clockfacePrinter(appts) {
	appPosition = [];
	var scope = localStorage.getItem('scope');
	var canvas = document.getElementById('clockface');
	ctx = canvas.getContext('2d');
	ctx.strokeStyle = jawnosInk();
	canvas.width = $('#background').width() ;
	canvas.height = $(window).height();

	var outer = (canvas.height - 95 ) * (	localStorage.getItem('scrollPositioner'));
	var appointment_events = appointmentEventMaker(appts,'size');
	var d = Date.now();
	var day = moment(d).format('d');
	var hour = moment(d).format('h');
	var hourWatch = hour;
	var min = moment(d).format('m');
	var second = moment(d).format('s');
	var radius;
	var height = canvas.height / 2 + (130 /2);
	var width = canvas.width / 2;
	ctx.font = "300 42px Arial";
	ctx.fillStyle = '#566778';
	ctx.font = "400 20px Arial";
	$.each([.999,.6,.5,.4,.3,.2],function(i,v) {
		radius = (outer * v * .9);
		ctx.beginPath();
		ctx.lineWidth = 8;
		ctx.stroke();
		ctx.closePath();
		var num;
		var ang;
		ctx.save('b');
		ctx.translate(width, height);

		for(num = 59; num > 0; num--) {
			ctx.beginPath();
			ang = num * Math.PI / 30;
			ctx.rotate(ang);
			ctx.translate(0, -radius - 15);
			ctx.rotate(-ang);
			var whole = num / 5;
			ctx.save('c');
			var minute_mover = Math.trunc((hour * 5) + ((min / 60) * 5));
			var new_arr = [];
			var ball_size = 60;
			if (i == 9) {
				new_arr = $.grep(appointment_events.age, function(n, i){ 
					ball_size = 60;
					return n.minute == num;
				});
			}
			if (i == 8) {
				new_arr = $.grep(appointment_events.millenium, function(n, i){ 
					ball_size = 60;
					return n.minute == num;
				});
			}
			if (i == 7) {
				new_arr = $.grep(appointment_events.century, function(n, i){ 
					ball_size = 60;
					return n.minute == num;
				});
			}
			if (i == 6) {
				new_arr = $.grep(appointment_events.decade, function(n, i){ 
					ball_size = 60;
					return n.minute == num;
				});
			}
			if (i == 4) {
				new_arr = $.grep(appointment_events.year, function(n, i){ 
					ball_size = 60;
					return n.minute == num;
				});
			}
			if (i == 3) {
				new_arr = $.grep(appointment_events.month, function(n, i){ 
					ball_size = 60;
					return n.minute == num;
				});
			}
			if (i == 2) {
				new_arr = $.grep(appointment_events.week, function(n, i){ 
					ball_size = 60;
					return n.minute == num;
				});
			}
			if (i == 1) {
				new_arr = $.grep(appointment_events.day, function(n, i){ 
					ball_size = 60;
					return (60 - n.minute) == num;
				});
			}
			if (i == 0) {
				new_arr = $.grep(appointment_events.hour, function(n, i){
					return (60 - n.minute) == num;
				});
				ball_size = 130;
			}
			if (new_arr.length > 0) {
				ctx.save('z');
				ctx.beginPath();
				ctx.strokeStyle = jawnosInk();
				ctx.lineWidth = 2;
				ctx.font = "700 22px Arial";
				ctx.fill();
				ctx.closePath();
				ctx.beginPath();
				$.each(new_arr,function(i,v) {
					ctx.fillStyle = new_arr[i].colour || jawnosInk();
					ctx.globalAlpha = 1;
					ctx.arc(0, 0, 30, (Math.PI * 2),.5, true);
					ctx.fill();


		//			appPosition.push([position , placement_number * 25 - 16, position + ctx.measureText(l['formatted_name']).width, placement_number * 25 +10, v]);
					ctx.arc(0, 0, 31, (Math.PI * 2),.5, true);
					ctx.fillText(new_arr[i].value.formatted_name,35,-10);
					ctx.stroke();
				});
				ctx.closePath();
				ctx.restore('z');
			}
			if (hour == whole || (hour == 12 && whole == 0)	) {
				if ( hour == 12 ) { hour = 0; }
				hourWatch = hour; 
			}
			ctx.restore('c');
			if ((num % 5) == 0 && i == 0) {
				ctx.font = "700 32px Arial";
				ctx.fillStyle = '#566778';
				var number = num
				if (scope == 'day') {
					number = (num / 2.5);
				}
				ctx.fillText(number, -(Math.PI * 2), 0);
				ctx.arc(0, 0, 32, (Math.PI * 2),0, true);
			}
			ctx.rotate(ang);
			ctx.translate(0, radius + 15);
			ctx.rotate(-ang);
			ctx.closePath();
		} 
		ctx.restore('b');
	});
	headerPrinter(ctx,appts,'Clockface');
	ctx.closePath();
}
