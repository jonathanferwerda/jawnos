
var currentBackground;
function backgroundPrinter(appts,respons) {
	canvas = document.getElementById('background');
	var ctx = canvas.getContext('2d');
	var n = Math.floor(appts['__specs']['random_number']) || 0;
	var backgrounds = appts['__specs']['backgrounds'];
	var background = appts['__specs']['background'];
	if (backgrounds.length > 0 && currentBackground != background['f']) {
		currentBackground = background['f'];

		var background_images_opacity = localStorage.getItem('background_images_opacity');
		$('#background').css({ 'opacity': background_images_opacity });
		canvas.height = $(window).height();
		canvas.width = $('#background').width();
		var img = new Image;
		img.onload = function(){

			var w = background['info']['width'];
			var h = background['info']['height'];
			var ch = canvas.height;
			var cw = canvas.width;
			var ih = 0;
			var iw = 0;
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
		img.src = '/file_open?file=' + background['f'] + '&app=' + background['app'] + '&timestamp=' + background['server_time'];

	}
	else {
		headerPrinter(ctx,appts,'background');
		clotheslineHanger(respons.clothesline);
	}
}