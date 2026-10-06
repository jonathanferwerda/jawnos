$(document).on('click', '.market_toggle', function() {
	marketOpener();
});

function marketOpener() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/market',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			windowMaker(response.window);
		}
	});


}