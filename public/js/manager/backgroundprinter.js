// The page backdrop: the user's picture, scaled to cover the canvas and
// centred (overflow is cropped, the way a wallpaper should crop), with a
// header + clothesline fallback when there is no picture to show.

var currentBackground;
function backgroundPrinter(appts,respons) {
	canvas = document.getElementById('background');
	var ctx = canvas.getContext('2d');
	var backgrounds = appts['__specs']['backgrounds'] || [];
	var background = appts['__specs']['background'];

	// the canvas has to be on screen before it can be measured - a hidden
	// canvas measures 0 wide, and a 0 wide canvas never shows the picture
	$('#background').show();
	canvas.height = $(window).height();
	canvas.width = $('#background').width();

	var key = background ? (background['f'] + ':' + canvas.width + 'x' + canvas.height) : '';
	if (backgrounds.length > 0 && background) {
		// same picture at the same size? leave the pixels alone
		if (currentBackground == key) { return; }
		currentBackground = key;

		var background_images_opacity = localStorage.getItem('background_images_opacity');
		$('#background').css({ 'opacity': background_images_opacity });
		var img = new Image;
		img.onload = function(){
			backgroundDraw(ctx, img, background['info'], canvas);
		};
		// if the file cannot be fetched, the page still gets its backdrop
		img.onerror = function(){
			backgroundFallback(ctx, appts, respons, canvas);
		};
		img.src = '/file_open?file=' + background['f'] + '&app=' + background['app'] + '&timestamp=' + background['server_time'];
	}
	else {
		backgroundFallback(ctx, appts, respons, canvas);
	}
}

// Cover-fit: scale by whichever axis needs the most, centre the overflow.
// No stored dimensions? stretch, rather than draw nothing.
function backgroundDraw(ctx, img, info, canvas) {
	var cw = canvas.width;
	var ch = canvas.height;
	var w = info ? info['width'] : 0;
	var h = info ? info['height'] : 0;
	ctx.save();
	ctx.imageSmoothingEnabled = true;
	ctx.imageSmoothingQuality = 'high';
	ctx.clearRect(0, 0, cw, ch);
	if (!w || !h) {
		ctx.drawImage(img, 0, 0, cw, ch);
	}
	else {
		var scale = Math.max(cw / w, ch / h);
		var dw = w * scale;
		var dh = h * scale;
		ctx.drawImage(img, (cw - dw) / 2, (ch - dh) / 2, dw, dh);
	}
	ctx.restore();
}

function backgroundFallback(ctx, appts, respons, canvas) {
	canvas = canvas || document.getElementById('background');
	canvas.width = $('#background').width();
	canvas.height = $(window).height();
	headerPrinter(ctx, appts, 'background');
	clotheslineHanger(respons ? respons.clothesline : undefined);
}
