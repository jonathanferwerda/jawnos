

var appPosition = [];
function timelinePrinter(appts,sort,offset) {
	appPosition = [];
	var pseudonymLoader = [];
	var scope = localStorage.getItem('scope');
	var canvas = document.getElementById('timeline');

	$('#timeline').show();
	canvas.width = $('#background').width();



	var temp_height = (canvas.height * .05) + clothesLineHeight;
	$.each(appts,function(i,v) {
		if (!v.list) { return true; }
		temp_height = (temp_height + (numeral(19)).value());
	});

	if (temp_height > $(window).height()) {
		$('#timeline').height(temp_height);
		canvas.height = temp_height;
	}
	else {
		canvas.height = $(window).height();
		$('#timeline').height(canvas.height);
	}
	ctx = canvas.getContext('2d');
	ctx.strokeStyle = 'black';
	ctx.clearRect(0,clothesLineHeight,canvas.width,canvas.height);
	ctx.fill();
	ctx.beginPath();
	headerPrinter(ctx,appts,'Timeline');
	ctx.save('init');

	ctx.strokeStyle = 'yellow';
	ctx.lineWidth = 5;
	ctx.moveTo(canvas.width / 2, 80);
	ctx.lineTo(canvas.width /2, canvas.height);
	ctx.fill();
	ctx.stroke();
	ctx.restore('init');
	ctx.moveTo(0, 80);
	ctx.lineWidth = 3;
	var placement_number = 2;
	var textPrinter = [];
	var appts_length = appts.length;

	$.each(appts, function(i,v) {

		if ( i.match(/^__/) ) { return true; }
		if ( !v.setting ) { return true; }
		ctx.strokeStyle = 'black';
		ctx.fillStyle = v.setting.colour || 'black';
		if (!v.list) { return true; }
		var ln = v.list.length;
		ctx.moveTo(0, canvas.height * .8);
		var appt_store = [];

		$.each(appts, function(appt_n,appt) {
			var appt_check = $.grep(appt_store, function(n,i) { return n.formatted_name == appt.formatted_name })
			if (appt_check.length == 0 && appt[scope + '_occurrences'] > 0) {
				appt_store.push(appt);
			}

		});
		var total_store_size = appt_store.length;

		for (var n = 0; n < ln; n++) {
			placement_number++;
			ctx.beginPath();

			var l = v.list[n];
			if (l.length == 0 ) { return true; }
			var occurrence = (n / ln) / canvas.height;
			ctx.font = "400 20px Arial";
			var position = (canvas.width/2) * l[scope + '_percent'];
			var verticalPosition = (placement_number * 28) + clothesLineHeight;

			if (v['placement_number']) {
				verticalPosition = v['placement_number'];
				placement_number--;
			}
			ctx.arc(position, verticalPosition, 10, 0, (Math.PI*2), true);

			appPosition.push([position - 40, verticalPosition - 10, position + 10, verticalPosition + 10, v]);
			ctx.fillStyle = 'black';
			if (l['total'] || l['amount']) {
				ctx.font = "400 14px Arial";
				var fillText = l['total'] ? '$' + l['total'] : '$' + l['amount'];
				ctx.fillText(fillText, position + 40, (  verticalPosition + 14 ));			
				ctx.font = "400 20px Arial";	
			}


			appPosition.push([position , verticalPosition - 26, position + ctx.measureText(l['formatted_name']).width, verticalPosition +10, v]);
			ctx.fill();
			ctx.stroke();
			ctx.strokeStyle = v.setting.colour || 'black';
			ctx.arc(position, verticalPosition, 9, 0, (Math.PI*2), true);
			var now = Date.now();
			if (clothesLinePos['moving'] + 300 < now) {
				pseudoGenerator(appts,l['type'],position - 20, verticalPosition - 10);
			}

			if (l[scope + '_start_percent']) {
				ctx.save('to the beginning');
				var startPosition = (canvas.width/2) * l[scope + '_start_percent'];

				if (l[scope + '_start_percent'] < 0) {
					appPosition.push([startPosition - 40, verticalPosition - 10, position + 10, verticalPosition + 10, v]);
				}
				else {
					appPosition.push([position - 40, verticalPosition - 10, startPosition + 10, verticalPosition + 10, v]);
				}

				ctx.lineWidth = 10;
				ctx.lineTo(startPosition, verticalPosition);
				ctx.strokeStyle = v.setting.colour || 'black';

				ctx.stroke();
				ctx.lineWidth = 2;
				ctx.lineTo(startPosition, verticalPosition);
				ctx.arc(startPosition + 7, verticalPosition, 7, 0, (Math.PI*2), true);
				ctx.stroke();
				ctx.restore('to the beginning');

			}
			if(!v['placement_number']) {
				var fillText = l['formatted_name'];	
				textPrinter.push({ text: fillText, x: position + 25, y: verticalPosition });
			}
			v['placement_number'] = verticalPosition;
			ctx.stroke();
			ctx.closePath()
		}
		ctx.moveTo(0, canvas.height * .2);

		ctx.stroke();
		 
	});
	$.each(textPrinter, function(i,v) {
		ctx.fillText(v.text, v.x, v.y);				
	});
	ctx.stroke();
}

function pseudoGenerator(appts,type,x,y) {
	var pseudonym = $.grep(appts['__specs']['pseudonyms'], function(n, i){ // just use arr
		return n['name'] == type;
	});

	if (pseudonym.length > 0) {
		var img = new Image;
		img.onload = function(){
			ctx.drawImage(img,x,y, 30, 30);
		};
		img.src = pseudonym[0]['icon'];
	}
}