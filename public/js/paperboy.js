var paperboy;
var paperboyInterval;
var last_paper_delivered = Date.now();
$(document).ready(function() {
	paperboyStart();
});

function paperboyStart() {
	var timestamp = Date.now();
	var browser_tab_id = sessionStorage.getItem('browser_tab_id') || bti;
	var browser_tab = localStorage.getItem('browser_tab') || bt;
	paperboy = new WebSocket(paperboy_url + '?timestamp=' + timestamp + '&browser_tab=' + browser_tab + '&browser_tab_id=' + browser_tab_id);
	paperboy.onopen = function (event) {
		clearInterval(paperboyInterval);
		console.log('Paperboy started');
		paperboyInterval = setInterval(function() {
			if (paperboy.readyState != 1) {
				paperboyStop();
			}
			else {
				var sender = JSON.stringify({ 'type': 'heartbeat' });
				paperboy.send(sender);
			}
		},2000);
		var sender = JSON.stringify({ type: 'refresher', 'last_paper_delivered': last_paper_delivered });
		paperboy.send(sender);
	}
	paperboy.onmessage = function (event) {

		var data = JSON.parse(event.data);
		paperPoster(data);

	}
	paperboy.onclose = function(event) {
		console.log('Paperboy stopped');
		paperboyStart();
	}
}

function paperPoster(data) {
	if (data.uuid) {
		var art = $('.article[uuid="' + data.uuid + '"]');
		if (data.remove == 'yes') {
			art.remove();
		}
		if (art.is(':visible')) {

			art.find('.article_content').html(data.content);
			art.find('.article_timestamp').attr('timestamp', data.timestamp);
			art.find('.article_warranty').attr('timestamp', data.warranty);
			art.find('.manager_file').val(data.manager_file);
			art.attr('uuid', data.uuid);
			art.attr('timestamp', data.timestamp);
			art.attr('warranty', data.warranty)
		}
		if ($('#category_selected').attr('category') == data.category || $('#category_selected').attr('category') == 'promo') {
			$('#content_area').prepend(data.art);
			var art = $('.article[uuid="' + data.uuid + '"]');
			art.find('.article_content').html(data.content);
			art.find('.article_timestamp').attr('timestamp', data.timestamp);
			art.find('.article_warranty').attr('timestamp', data.warranty);
			art.find('.manager_file').val(data.manager_file);
		}

	}
}

function paperboyStop() {

	if ( paperboy ) { paperboy.close(); paperboy = undefined;	delete paperboy; };


}


document.addEventListener("visibilitychange", function(e) { 
	if (e.returnValue == true) {
		paperboyStart();
	}
});