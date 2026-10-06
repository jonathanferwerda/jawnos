function calendarPrinter(appts,sort) {

	var scope = localStorage.getItem('scope');
	var canvas = document.getElementById('calendar');
	ctx = canvas.getContext('2d');

	ctx.beginPath();
	ctx.moveTo(0, canvas.height * .9);
	ctx.strokeStyle = 'black';
	canvas.width = $(window).width() ;
	canvas.height = $(window).height();
	headerPrinter(ctx,appts,'Calendar');
	
	var totalHeight = canvas.height * .9;
	var totalWidth = canvas.width;
	var rows = 5;
	var columns = 7;
	var boxHeight = totalHeight / rows;
	var boxWidth = totalHeight / columns;
	var cursor = { left: 0, top: canvas.height * .1 };
	for (var d = 0; d <= rows; d++) {
		for (var w = 0; w <= columns; w++) {

			var boxBottom = boxHeight + cursor.top;
			var boxRight = boxHeight + cursor.left;
			if (boxRight > totalWidth) {
				cursor.left = 0;
			}

			ctx.fillRect(cursor.left, cursor.top, cursor.left + boxWidth, cursor.top + boxHeight );
			cursor.left = boxRight;
			cursor.top = boxBottom;
		}
	}


	ctx.stroke();

}