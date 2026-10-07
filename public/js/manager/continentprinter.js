function continentPrinter(appts,sort) {

	var scope = localStorage.getItem('scope');
	var canvas = document.getElementById('continent');
	ctx = canvas.getContext('2d');
	canvas.width = $('#background').width() ;
	canvas.height = $(window).height();
	ctx.beginPath();
	ctx.fillStyle = 'red';
	ctx.strokeStyle = jawnosInk();
	$.each(appts['__continent'], function(i,v) {

		var lon = ((v.longitude + 82)) + (canvas.width / 2);
		var lat = ((v.latitude - 42) ) + (canvas.height / 2);
		ctx.arc(lat, lon, 16, 0, (Math.PI*2), true);
		ctx.fill();
		ctx.stroke();
	});

	ctx.moveTo(0, canvas.height * .8);
	ctx.strokeStyle = jawnosInk();

	ctx.save('j');
	headerPrinter(ctx,appts,'Continent');
	ctx.restore('j');


}