const images = [
	<% foreach my $i (@{$images}) { %>
		"<%= $i %>", 
	<% } %>
];
var payment;
var tree = {};
$(document).on('ready', function() { treeMaker() });
function treeMaker() {
	tree = {
		files: $('#files').find('.file'),
		songs: [],
		past_songs: [],
		all_songs: [],
		seek: 0,
		song_id: 0,
		sound: { playing: undefined, _state: undefined },
		howls: 0,
		current_track: 0,
	};
	for (n = 0; n <= tree.files.length - 1; n++) {
		if (tree.files[n].textContent !== undefined) {
			tree.songs.push(tree.files[n].textContent);
			tree.all_songs.push(encodeURI(tree.files[n].textContent));
		}
	}
}
treeMaker();


function howlMaker() {

	Howler.stop();

	tree.sound = new Howl({
		src: tree.songs,
		volume: 1,
		html5: true,
		onplay: function() {
			var total = tree.sound.duration();
			$('#progress_bar').attr('max', total);
			$('#total_progress').text(numeral(total).format('00:00'));
			interval = setInterval(function(){
			  var seek = tree.sound.seek();
			  $('#progress_bar').attr('value', seek);
			  var human_seek = seek / 60;
			  $('#elapsed_progress').text(numeral(seek).format('00:00'));
			}, 300);
		},
		onpause: function() {
			clearInterval(interval);
		},
		onend: function() {
			clearInterval(interval);
			$('#progress_bar').attr('value', 0).attr('max', 0);
			$('#total_progress').text(numeral(0).format('00:00'));
			$('#elapsed_progress').text(numeral(0).format('00:00'));
			tree.past_songs.push(tree.songs.shift());
			
			if (tree.songs.length == 0) {
				for (var n = 0; n <= tree.all_songs.length; n++ ) {
					tree.songs.push(tree.all_songs[n]);
				}
				tree.past_songs = [];
			}
			howlMaker();
		},
	});
	tree.sound.play();
	$('#play_logo').attr('src', '/icons/pause.jpg');
	tree.howls++;
	$('.playing').find('.lettering').css({ 'height': '22px' });
	$('.playing').find('.uppercase').css({ 'height': '20px' });
	$('.playing').removeClass('playing');
	var track_number = tree.past_songs.length + 1;
	$('#track_' + track_number).parent().addClass('playing').find('.lettering').css({ 'height': '25px' });
	$('#track_' + track_number).parent().addClass('playing').find('.uppercase').css({ 'height': '25px' });
	
}

$(document).on('click', '#play', function() {
	if (tree.sound._state == undefined) {
		howlMaker()
	}
	else if (tree.howls > 0 && tree.sound.playing() == false) {
		tree.sound.play();
		$('#play_logo').attr('src', '/icons/pause.jpg');
	}
	else {
		tree.sound.pause();
		$('#play_logo').attr('src', '/icons/play.jpg');
	}
});

$(document).on('click', '#prev', function() {
	tree.songs.unshift(tree.past_songs.pop());
	howlMaker()
});

$(document).on('click', '#next', function() {
	tree.past_songs.push(tree.songs.shift());
	howlMaker();
});

$(document).on('click', '.track_item', function() {
	var item = $(this);
	var number = item.attr("number");
	var unformatted_filename = item.find('.file').text();
	var filename = encodeURI(unformatted_filename);

	for (var n = 0; n <= tree.all_songs.length; n++) {
		if (tree.all_songs[n] == filename) {
			tree.past_songs = tree.all_songs.slice(0, number - 1);
			tree.songs = tree.all_songs.slice(number - 1);
			howlMaker();
			return;
		}
	}
});

$(document).on('click', '#progress_bar', function(e) {
  var total_width = $('#progress_bar').width();
  var current_location = e.offsetX;
  var seek_to = (current_location / total_width) * tree.sound.duration();
  tree.sound.seek(seek_to);
 });

$(document).on('keyup', '#search', function() {
	var search = $('#search').val();
	console.log('searching ' + search);
	$.ajax({
		url: '/search',
		type: 'POST',
		data: { search: search },
		success: function(response) {
			$('#main_display').html(response);
			treeMaker();
		}
	});

});	
$(document).on('click', '#payment_toggle', function() {
	$.ajax({ 
		url: '/payment',
		type: 'POST',
		success:function(response){
			payment = JSON.parse(response);
			console.log(payment);
			var win = window.open(payment.payment_link.url, '_blank');
			if (win) {
				//Browser has allowed it to be opened
				win.focus();
			} else {
				//Browser has blocked it
				alert('Please allow popups for this website');
			}
		}
	});
});