
var currentBackground;
function backgroundPrinter(appts,respons) {
	canvas = document.getElementById('background');
	var ctx = canvas.getContext('2d');
	var n = Math.floor(appts['__specs']['random_number']) || 0;
	var backgrounds = appts['__specs']['backgrounds'] || [];
	var background = appts['__specs']['background'];
	if (backgrounds.length > 0 && background && currentBackground != background['f']) {
		currentBackground = background['f'];

		var background_images_opacity = localStorage.getItem('background_images_opacity');
		$('#background').css({ 'opacity': background_images_opacity });
		// the canvas has to be on screen before it can be measured - a hidden
		// canvas measures 0 wide, and a 0 wide canvas never shows the picture
		// (and currentBackground above means it would never be retried)
		$('#background').show();
		canvas.height = $(window).height();
		canvas.width = $('#background').width();
		var img = new Image;
		img.onload = function(){
			var w = background['info'] ? background['info']['width'] : 0;
			var h = background['info'] ? background['info']['height'] : 0;
			var ch = canvas.height;
			var cw = canvas.width;
			var ih = 0;
			var iw = 0;
			// no stored dimensions? fill the canvas rather than draw nothing
			if (!w || !h) {
				ctx.drawImage(img, 0, 0, cw, ch);
				return;
			}
			if (h > w) {
				ch = (w / h) * cw;
				ih = (canvas.height - ch) / 2;
			}
			else {

				cw = (w / h) * ch;
				iw = (canvas.width - cw) / 2;
			}

			ctx.drawImage(img,iw,ih, cw, ch);
		};
		// if the file cannot be fetched, the page still gets its backdrop
		img.onerror = function(){
			headerPrinter(ctx,appts,'background');
			clotheslineHanger(respons.clothesline);
		};
		img.src = '/file_open?file=' + background['f'] + '&app=' + background['app'] + '&timestamp=' + background['server_time'];

	}
	else {
		headerPrinter(ctx,appts,'background');
		clotheslineHanger(respons.clothesline);
	}
}
