var mao = {};
var misses = {};
// Play/pause glyphs follow the selected icon set; the music window stashes the
// resolved paths on #play_logo (see apps/music/music.html.ep).
function jawnosPlayIcon() { var s = $('#play_logo').attr('play_icon'); return s || '/icons/play.jpg'; }
function jawnosPauseIcon() { var s = $('#play_logo').attr('pause_icon'); return s || '/icons/pause.jpg'; }
$(document).on('ready', function() { 
	treeMaker();
	mao = settingGrabber({ 'app': 'music', 'setting': 'mao' });
});
$(document).on('click', '#music_toggle', function() {
	musicToggle();
});

function musicToggle(files) {
	var url = '/manager/music';
	var timestamp = Date.now();
	var jmiss = JSON.stringify(misses);
	if ($('#music').length == 0 || files ) {
		console.log(files);
		var jfiles;
		if (files) {
			jfiles = JSON.stringify(files);
		}
		$.ajax({
			url: url,
			type: 'GET',
			data: { window_maker: 'yes', timestamp: timestamp, misses: jmiss, files: jfiles },
			success: function(response) {

				var window_id = windowMaker(response);

				musicInit();
				if (files) {
					mediaMaker();
				}
			}, error: function (response) {  }
		});
	}
	else {
		var music_window = $('#music').closest('.wind').attr('id');
		$('#' + music_window).show();
		$('.little_window[app="music"]').hide()
		topLevelNow($('#' + music_window));
		musicInit();
	}
}

async function musicInit(method) {
	treeMaker();
	if (method != 'search') {
		tree.sound.volume = 0;
	}
	var player = JSON.parse($('#music_player_data').text());

	//tree.sound.currentTime = player.currentTime;
	$('#music_player_data').load("/manager/cache_get?app=music&context=player&json=yes");
	if (isJson($('#music_player_data').text()) && method != 'search') {

		var jpd = $('#music_player_data').text();
		var pd = JSON.parse(jpd);
		$('#video').attr('theatre_mode', pd.theatre_mode);
		$('#video').attr('type', pd.type);
		mediaMaker({ src: pd.file, currentTime: pd.currentTime, method: 'benign', timestamp: Date.now(), state: pd.state, });
		if (method != 'search') {
			tree.sound.currentTime = pd.currentTime;
		}
	//	if (method != 'search') {
			tree.sound.state = pd.state;
	//	}
		$('#music_player_data').text(jpd);

		$('.music_file').removeClass('playing');
		var mf = $('.music_file[file="' + pd.file + '"]');
		mf.addClass('playing');
		var playing = $('.playing');

		tree.sound.textTracks[0].mode = $('#video_subtitle_toggle').attr('status');

		if ($('#video').attr('type') == 'audio') {
			$('#video').hide();
		}
		tree.current_track = playing.attr('number');
	//	tree.sound.volume = 1;
		thisTrack(playing.closest('.track_item'));
		if (pd.state == 0 && method != 'search') {
			tree.sound.pause();
		}
		if (pd.resizes) {
			$('#music_albums').height(pd.resizes.music_albums.height);
			$('#music_albums').scrollTop(pd.resizes.music_albums.scrollTop);
			$('#music_artists').height(pd.resizes.music_artists.height);
			$('#music_albums').scrollTop(pd.resizes.music_albums.scrollTop);
			$('#music_files').css({ 'top': ($('#music_albums').height() + 100) + 'px' });
			var i = $('#interface').height();
			var mc = $('#music').find('.media_controls').height();
			var mm = $('#music_albums').height();
			$('#music_files').height($('#music').height() - (mm + mc + i));
		}
		playerCacheSaver();
	}


	$('.file_duration').each(function(i,v) {
		$(v).text(numeral($(v).text()).format('00:00:00'));
	});
	$('#video').trigger('mouseenter');
	setTimeout(function() {
		if ($('#video').attr('type') != 'video') {	
			$('#video').hide();
		}
	},200);

	$('#music_artists, #music_albums').resizable({
		start: function(p) {
		},
		resize: function(p,j) {
			if (p.target.id == 'music_artists') {
				$('#music_albums').height(j.size.height);
			}
			else if (p.target.id == 'music_albums') {
				$('#music_artists').height(j.size.height);
			}
			var newTop = ($('#music_albums').height() + 100) + 'px';
			$('#music_files').css({ 'top': newTop });
			var i = $('#interface').height();
			var mc = $('#music').find('.media_controls').height();
			var mm = $('#music_albums').height();
			$('#music_files').height($('#music').height() - (mm + mc + i));	
		},
		stop: function(p) { 
		}
	});
	var mc = $('#music_configuration');
	if (mc.is(':visible')) {
		var z_index = $('#interface').css('z-index') + 1;
		mc.css({ 'z-index': z_index });
	}
}
var lastMusicCacheHtml;
function playerCacheSaver(type) {
	var timestamp = Date.now();
	var jpd;
	if (timestamp - tree.lastCache >= 5000) {
		var unlocked = 0;
		if ($('#music').attr('unlock')) { unlocked = 1; }
		var playerData = { 
			number: tree.sound.current_track, 
			'currentTime': tree.sound.currentTime, 
			file: tree.songs[0].file, 
			volume: tree.sound.volume, 
			state: tree.sound.state, 
			theatre_mode: $('#video').attr('theatre_mode'), 
			unlocked: unlocked,
			resizes: {
				music_albums: { bottom: $('#music_albums').css('top'), height: $('#music_albums').height() },
				music_artists: { bottom: $('#music_artists').css('top'), height: $('#music_albums').height() },
				music_files: { top: $('#music_files').css('top'), height: $('#music_files').height() }
			},
			type: $('#video').attr('type'),
			method: 'playerCache',
			subtitle_mode: tree.sound.textTracks[0].mode
		};
		jpd = JSON.stringify(playerData);


		if (type == 'ajax' || ws['music'].readyState != 1) {
			cacheSet({ 'app': 'music', 'context': 'player'}, playerData);
			var html = $('#music').parent().html();
			if (html != lastMusicCacheHtml) {
				cacheSet({'app': 'music', 'context': 'content' },{ contents: html });
			}
		}
		else {
			ws['music'].send(jpd);
		}
		$('#music_player_data').text(jpd);
	}
	return jpd;
}

function treeMaker() {
	var sound = tree.sound;
	tree = {
		files: $('#files').find('.file'),
		songs: [],
		past_songs: [],
		all_songs: [],
		seek: 0,
		song_id: 0,
		current_track: 0,
		speaker: new Audio,
		ctx: new AudioContext,
		sound: document.getElementById('video'),
		lastCache: 0
	};
	if (sound) {
	//	tree.sound = sound;
	}
	if (tree.sound) {
		tree.sound.onstatechange = function(i) {
			if (tree.sound.state == 1) {
				$('#play_logo').attr('src', jawnosPlayIcon());
			}
			else {
				$('#play_logo').attr('src', jawnosPauseIcon());
			}
		};
	}
	for (n = 0; n <= tree.files.length - 1; n++) {
		if (tree.files[n].textContent !== undefined) {
//			JSON.parse($(tree.files[n]).val());
			var info;
			if (isJson($('.file_json[file_uuid="' + $(tree.files[n]).attr('file_uuid') + '"]').text())) {
				info = JSON.parse($('.file_json[file_uuid="' + $(tree.files[n]).attr('file_uuid') + '"]').text());
			}
			var data = { 
				encodedFile: encodeURI(tree.files[n].textContent), 
				file: tree.files[n].textContent, 
				type: $(tree.files[n]).attr('type'), 
				app: $(tree.files[n]).attr('app'),
				remote_uuid: $(tree.files[n]).attr('remote_uuid'),
				computer_name: $(tree.files[n]).attr('computer_name'),
				colour: $(tree.files[n]).attr('colour'),
				info: info,
			};
			tree.songs.push(data);
			tree.all_songs.push(data);
		}
	}
	$('.file_duration').each(function(i,v) {
		if ($(v).attr('initialized') != 'yes') {
			$(v).text(numeral($(v).text()).format('00:00:00'));
			$(v).attr('initialized', 'yes');
		}
	});
}
treeMaker();


var musicSearchTimeout;
$(document).on('keyup', '#music_search', function(e) {
	if (e.keyCode == 13) {
		$('.music_album').attr('active', 'no');
		$('.music_artist').attr('active', 'no');
		searchMusic();
	}
});


var interval;
function mediaMaker(data) {
	if (typeof data != 'object') { data = {}; }
	var time = data['time'];
	var timestamp = data['timestamp'] || Date.now();
	var method = data['method'];
	var file = data['file'] || tree.songs[0].file;
	var uri_track = encodeURIComponent(file);
	if (mao['srv'] == 'on') {
		$.ajax({
			url: '/play?track=' + uri_track,
			success: function(response) {}
		});
	}
	if (1 == 1) {
		var id = 'video';
		var vid = $('#' + id);
		var window_id;

		if (file) {
			var url = '/play?track=' + uri_track;

			tree.sound = document.getElementById('video');
			if (data['state'] != 0) {
				$('#play_logo').attr('src', jawnosPauseIcon());
			}
			if (method != 'benign') {

				if (tree.songs[0].type == 'audio') {
					$('#music_library').show();
					$('#video').hide();
					$('#video').attr('type', 'audio');
					$('#album_cover').show();
					var miss = $('#video').attr('miss');
				//	$('#' + miss + '_controls').show();
				}
				else {
					$('#video').attr('type', 'video').show();

					$('#album_cover').hide();
				}

				tree.current_track = tree.past_songs.length + 1;

				if (data['state'] != 0) {
					tree.sound.play();
					tree.sound.load();
					tree.sound.state = 1;
				}
				else {
					tree.sound.state = 0;
				}
				tree.sound.saved_volume = master_volume;
				tree.sound.volume = 0.00001;

				if (tree.songs[0].remote_uuid) {
					url += '&remote_uuid=' + tree.songs[0].remote_uuid;
				}

				tree.sound.src = url
				var st_url = url + '&subtitle=yes';
				document.getElementById('video_subtitles').src = st_url;
				document.getElementById('video_subtitles').addEventListener('error', function() {
					this.removeAttribute('src');
				});
				tree.sound.video = true;
		//		tree.sound.controls = true;
				tree.sound.html5 = true;
				tree.sound.playbackRate = 1;
				tree.sound.currentTime = time || 0;
				tree.sound.queued = 0;
				remoteTrackToggle({
					file: file,
					toggle: 'on',
					seek: tree.sound.currentTime
				});
			}
			if ($('#video').attr('theatre_mode') == 'on') {
				theatreModeOn();
			}
			else {
				theatreModeOff();
			}
			tree.sound.onplaying = function() {
				var total = tree.sound.duration;
				$('#progress_bar').attr('max', total);
					var endsong = tree.sound.duration;
					$('#total').text(endsong);


					
					var app = tree.songs[0].app;
					
					if (method != 'benign') {
						playing_now();
					}
					else {
						var playing = $('.playing');
						var current_track = playing.attr('number');
						treeMaker();
						thisTrack(playing.closest('.track_item'));
						tree.current_track = current_track;
						playing_now('update');
					}
					vidControls['video'] = [];
					if (tree.songs[0].info.chapters) {

						$.each(tree.songs[0].info.chapters, function(i,v) {
							vidControls['video'].push(v.start_time);
						});
					}

					tree['music_data'] = musicAppointmentWriter('start');
					if ($('#video').attr('theatre_mode') == 'on') {
						theatreModeOn();
					}
					else {
						theatreModeOff();
					}
					clearInterval(interval);
					interval = setInterval(function(){
						var trackCues = tree.sound.textTracks[0].cues;
						if (trackCues.length > 0) {
							$('#video_subtitle_toggle').show();
							if ($('#video_subtitle_toggle').attr('status') == 'showing') {
								tree.sound.textTracks[0].mode = 'showing';
							}
							else {
								tree.sound.textTracks[0].mode = 'hidden';
							}
						}
						else {
							$('#video_subtitle_toggle').hide();
							tree.sound.textTracks[0].mode = 'hidden';
						}
						var pre_value = $('#progress_bar').val();
						var cursor = tree.sound.currentTime;
						if (pre_value > cursor + 2 || pre_value < cursor - 2 && tree.sound.exempt_seek != 1) {
							remoteTrackToggle({
								file: tree.songs[0].file,
								toggle: 'seek',
								seek: tree.sound.currentTime
							});
						}
						tree.sound.exempt_seek = 0;
						$('#progress_bar').attr('value', cursor);
						$('#cursor').text(cursor);
						$('#total_progress').text(numeral(tree.sound.duration).format('00:00:00'));
						$('#elapsed_progress').text(numeral(tree.sound.currentTime).format('00:00:00'));
						playerCacheSaver();
						if (cursor >= tree.sound.duration - 3.9 && tree.sound.queued != 1) {
							remoteTrackToggle({
								file: tree.songs[1].file,
								toggle: 'on',
								music_data: tree.songs[1],
								seek: 0,
								queuing: 1
							});
							tree.sound.queued = 1;
						}
					}, 1000);
					
					$('#play_logo').attr('src', jawnosPauseIcon());
					
				};
				tree.sound.onpause = function() {
					clearInterval(interval);
			
					$('#play_logo').attr('src', jawnosPlayIcon());
			
				};
				tree.sound.onerror = function() {
					nextTrack();
				};
				tree.sound.onended = function() {
					clearInterval(interval);
					$('#progress_bar').attr('value', 0).attr('max', 0);
					$('#total_progress').text(0);
					$('#elapsed_progress').text(0);
					$('#' + id).hide();
		
					tree.past_songs.push(tree.songs.shift());
					var app = tree.songs[0].app;
					if (tree.songs.length == 0 ) {
						if ($('.music_repeat').attr('enabled') == 'on') {
							for (var n = 0; n <= tree.all_songs.length; n++ ) {
								tree.songs.push(tree.all_songs[n]);
							}
							tree.past_songs = [];
						}
						else {
							tree.sound.pause();
							$('.playing').removeClass('playing');
							musicAppointmentWriter('stop','no');	
						}
					}
					mediaMaker();
				};
		}
	}
	playerCacheSaver();
	var html = $('#music').parent().html();
	cacheSet({'app': 'music', 'context': 'content' },{ contents: html });
}

function remoteTrackToggle(data) {
	var file = data['file'];
	var seek = data['seek'] || tree.sound.currentTime;
	var toggle = data['toggle'];
	var music_data = data['music_data'] || tree.songs[0];
	if (data['queuing'] != 1) {
		tree.sound.volume = 0.000001;
	}
	if (mao['me'] == 'off') {

	}
	var remoted = 0;
	$.each(mao, function(i,v) {
		if (i.match("\\.")) {
			if (v == 'on' && $('.music_audio_output_select[value="' + i + '"]').length > 0) {
			//	tree.sound.volume = 0;
				var timestamp = Date.now();
				var tr = { queuing: data['queuing'], timestamp: timestamp, volume: master_volume, method: 'transmitter', music_data: music_data, file: file, domain: i, toggle: toggle, seek: seek };
				var jtr = JSON.stringify(tr);
				ws['music'].send(jtr);
				remoted = 1;
			}
		}
	});
	if (data['queuing'] != 1) {
		if (mao['me'] == 'on' && remoted == 0) {
			tree.sound.volume = master_volume;
		}
	}
}


function musicTitleMaker(object) {
	var app = $('.playing').find('.file');
	var album = app.attr('album');
	var artist = app.attr('artist');
	var song = app.attr('song');
	var video = document.getElementById('video');
	var canvas = document.createElement('canvas');
	var image;


	if (object == 'object') {
		var playing;
		if ($('#video').is(':visible') && advertise_watching == 'on') {
			var ratio = video.videoWidth / video.videoHeight;
			canvas.width = 640 || 0;
			canvas.height = ratio * video.videoHeight || 0;
			canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
			image = canvas.toDataURL('image/png');
			playing = app.closest('.track_item').html();
		}
		else {

		}
		return {
			artist: artist,
			album: album,
			song: song,
			image: image,
			width: canvas.width,
			height: canvas.height,
			ratio: ratio,
			playing: playing
		};
	}
	else {
		return (artist || '') + ' - ' + (album || '') + ' - ' + (song || '');
	}
}

$(document).on('click', '#music_list_view', function() {
	if ($('#video').attr('theatre_mode') == 'on') {
		theatreModeOff();
	}
	else {
		theatreModeOn();
	}
});

function theatreModeOn() {
	$('#music_library').hide();
	$('#video').show();
	var bs = $('#video').attr('big_style');
	$('#video').attr('style', bs);
	$('#music').css({'background-color':'black'});
	$('#video').attr('theatre_mode', 'on');
	if ($('#video').attr('type') == 'audio') {
		$('#video').hide();
		var src = $('.playing').closest('.track_item').find('.music_file_thumb').attr('src');
		$('#music_album_cover').attr('src', src).show();
	}
	else if ($('#video').attr('src')) {
		$('#video').show();
		$('#interface').hide();
		$('#music_padlock_toggle').hide();
		$('#music_configuration_toggle').hide();
		$('#music_album_cover').hide()
	}
}

function theatreModeOff() {
	$('#music_library').show();
	$('#music').css({'background-color': $('#music').attr('background_colour')});
	if ($('#video').attr('type') == 'video') {
		var ts = $('#video').attr('thumb_style');
		$('#video').attr('style', ts);
		$('#video').attr('theatre_mode', 'off'); 
	}
	else {
		$('#video').hide();
	}
	$('#interface').show();
	$('#music_padlock_toggle').show();
	$('#music_configuration_toggle').show();
	$('#music_album_cover').hide();
	$('#video').attr('theatre_mode', 'off'); 
}

$(document).on('click', '#video_subtitle_toggle', function() {
	var mode = v.textTracks[0].mode;
	var vst = $(this);
	if (mode == 'showing') {
		v.textTracks[0].mode = 'hidden';
		vst.attr('status', 'hidden');
	}
	else {
		v.textTracks[0].mode = 'showing';
		vst.attr('status', 'showing');
	}
	settingSetter({ 'app': 'music', 'setting': 'subtitles', 'value': v.textTracks[0].mode });
});

function musicAppointmentWriter(type,mute) {
	var app = $('.track_item.playing').find('.file');
	var duration = tree.sound.duration;
	var album = app.attr('album');
	var artist = app.attr('artist');
	var song = app.attr('song');
	var words = artist + ' - ' + song;
	var filename = app.text();
	var timestamp = Date.now();
	var musicData = { 
		app: musicTitleMaker(),
		timestamp: timestamp,
		type: type, 
		account: 'gallery',
		source: 'music',
		unit: tree.sound.duration + 's',
		file: filename,
		notes: musicTitleMaker(),
		mute: mute,
		words: words,
		duration: '-' + duration + 's',
		source: 'music',
		currentTime: tree.sound.currentTime,
		total_time: duration,
		title: musicTitleMaker('object'),
		interface: $('#interface').html(),

	};
	if (song != undefined && type != 'data_entry') {
		$.ajax({
			url: '/manager/reset',
			type: 'POST',
			data: musicData,
			success:function(response) {
				continent_record(musicTitleMaker(),timestamp);
			}
		});
	}
	return musicData;
}

$(document).on('click', '#play', function() {
	if (tree.sound.src == '') {
		mediaMaker({ file: tree.songs[0].file });
	}
	else if (tree.sound.state == 0) {
		tree.sound.play();
		tree.sound.state = 1;
		$('#play_logo').attr('src', jawnosPauseIcon());
		remoteTrackToggle({
			file: tree.songs[0].file,
			toggle: 'on',
			seek: tree.sound.currentTime
		});
	}
	else {
		tree.sound.pause();
		tree.sound.state = 0;
		$('#play_logo').attr('src', jawnosPlayIcon());
		remoteTrackToggle({
			file: tree.songs[0].file,
			toggle: 'off',
			seek: tree.sound.currentTime
		});
	}
	playerCacheSaver();
	var html = $('#music').parent().html();
	cacheSet({'app': 'music', 'context': 'content' },{ contents: html });
});

$(document).on('click', '#prev', function() {
	prevTrack();
});

function prevTrack() {
	if (tree.past_songs.length > 0) {
		tree.songs.unshift(tree.past_songs.pop());
	}
	mediaMaker()
}

function nextTrack() {
	if (tree.songs.length == 0) {
		if ($('.music_repeat').attr('enabled') == 'on') {
			for (var n = 0; n <= tree.all_songs.length; n++ ) {
				tree.songs.push(tree.all_songs[n]);
			}
			tree.past_songs = [];
		}
		else {
			tree.sound.pause();
			$('.playing').removeClass('playing');
		}
	}
	else {
		tree.past_songs.push(tree.songs.shift());
	}
	mediaMaker();
}

$(document).on('click', '#next', function() {
	nextTrack();
});

$(document).on('click', '.track_item', function(e) {
	var item = $(this);
	var file = item.attr('file');
	if ($(e.target).hasClass('music_information_toggle')) {
		musicInformation(file);
	}
	else if ($(e.target).closest('.chapter_thumb')) {
		var ch = $(e.target).closest('.chapter_thumb');
		thisTrack(item);
		mediaMaker({ time: ch.attr('start_time') });
	}
	else {
		thisTrack(item);
		mediaMaker();
	}
});

function thisTrack(item) {
	var number = item.attr("number");
	var unformatted_filename = item.find('.file').text();
	var filename = encodeURI(unformatted_filename);
	treeMaker();
	for (var n = 0; n <= tree.all_songs.length; n++) {
		if (tree.all_songs[n]) {
			if (tree.all_songs[n].encodedFile == filename) {
				tree.past_songs = tree.all_songs.slice(0, number - 1);
				tree.songs = tree.all_songs.slice(number - 1);
				return;
			}
		}
	}
}

function musicInformation(file) {
	var td = $('.track_description[file="' + file + '"]');
	if (td.is(':visible')) {
		td.hide();
	}
	else {
		td.show();
	}
}

function musicWindowResizes() {
	var resizes = {
		music_albums: { bottom: $('#music_albums').css('top'), height: $('#music_albums').height(), scrollTop: $('#music_albums').scrollTop() },
		music_artists: { bottom: $('#music_artists').css('top'), height: $('#music_albums').height(), scrollTop: $('#music_artists').scrollTop() },
		music_files: { top: $('#music_files').css('top'), height: $('#music_files').height(), scrollTop: $('#music_files').scrollTop() }
	};
	return resizes;
}

$(document).on('click change', '#progress_bar', function(e) {
  var total_width = $('#progress_bar').width();
  var current_location = e.offsetX;
  var seek_to = (current_location / total_width) * tree.sound.duration;
  tree.sound.currentTime = seek_to;
	remoteTrackToggle({
		file: tree.songs[0].file,
		toggle: 'seek',
		seek: tree.sound.currentTime
	});
 });

var master_volume = 1;
$(document).on('click', '#volume_control', function(e) {
	var total_width = $('#volume_control').width();
  var current_location = e.offsetX;
  var new_volume = (current_location / total_width);
  tree.sound.volume = new_volume;
	master_volume = new_volume;
	$('#volume_control').attr('value', new_volume);
});

$(document).on('click', '.music_artist', function(e) {
	if (e.originalEvent.ctrlKey == true) {
		if ($(this).attr('active') == 'yes') {
			$(this).attr('active', 'no');
		}
		else {
			$(this).attr('active', 'yes');
		}
	}
	else {
		if ($(this).attr('active') == 'yes') {
			$('.music_artist').attr('active', 'no');
		}
		else {
			$('.music_artist').attr('active', 'no');
			$(this).attr('active', 'yes');
		}
	}
	searchMusic({ source: 'artist' });
});

$(document).on('click', '.music_album', function(e) {
	if (e.originalEvent.ctrlKey == true) {
		if ($(this).attr('active') == 'yes') {
			$(this).attr('active', 'no');
		}
		else {
			$(this).attr('active', 'yes');
		}
	}
	else {
		if ($(this).attr('active') == 'yes') {
			$('.music_album').attr('active', 'no');
		}
		else {
			$('.music_album').attr('active', 'no');
			$(this).attr('active', 'yes');
		}
	}
	searchMusic({ source: 'album' });
});

function searchMusic(data) {
	if (typeof data != 'object') { data = {}; }
	var searching = data['search'];
	var list = data['list'] || [];
	var same_order = data['same_order'];
	var new_settings = data['new_settings'];
	var source = data['source'];
	if (new_settings) {
		new_settings = JSON.stringify(new_settings);
	}
	var artist = [];
	$('.music_artist').each(function(i,v) {
		if ($(v).attr('active') == 'yes') {
			artist.push({ 'artist': $(v).attr('artist'), 'path': $(v).attr('path') });
		}
	});
	var album = [];
	$('.music_album').each(function(i,v) {
		if ($(v).attr('active') == 'yes') {
			album.push({ 'album': $(v).attr('album'), 'path': $(v).attr('path') });
		}
	});
	artist = JSON.stringify(artist);
	album = JSON.stringify(album);

	var artistScroll = $('#music_artists').scrollTop();
	var albumScroll = $('#music_albums').scrollTop();


	var search = searching || $('#music_search').val();
	var unlock = $('#music').attr('unlock');
	$('body').css({ 'cursor': 'progress' });
	var folders = musicFolderChecker();
	var nowPlaying = {};
	if (tree.sound) {
		if (tree.sound.state == 1) {
			nowPlaying = tree.songs[0];
		}
	}
	var jnowPlaying = JSON.stringify(nowPlaying);
	var jlist = JSON.stringify(list);
	var resizes = musicWindowResizes();
	var jresizes = JSON.stringify(resizes);
	var jmiss = JSON.stringify(misses);
	var theatreMode =	$('#video').attr('theatre_mode');
	$.ajax({
		url: '/music/search',
		type: 'POST',
		data: { 
			search: search, 
			window_maker: 'yes', 
			folders: folders, 
			artist: artist, 
			album: album, 
			unlock: unlock, 
			now_playing: jnowPlaying, 
			list: jlist, 
			same_order: same_order, 
			new_settings: new_settings,
			resizes: jresizes,
			misses: jmiss
		},
		success: function(response) {
			clearInterval(vidControls['video_video_interval']);
			$('body').css({ 'cursor': 'auto' });

			var v = document.getElementById('video');
			var src = v.src;
			var currentTime = v.currentTime;
			var timestamp = Date.now();
			var state = v.state;


			treeMaker();

			var configOpen = $('#music_configuration').is(':visible');
			var oldMusic = $('#music').html();
			musicWindowResizes();
			if (1 == 0 && v.src) {
				$('#temporary_workspace').append(v);
				$('#music').find('#video').remove();
				windowMaker(response.html);
				var nv = $('#music').find('#video');
			//	var id = nv.attr('id');
			//	$('#temporary_workspace').find('video').attr('id', id);

				nv.remove();

				$('#music').find('.video_container').append(v);

				$('#temporary_workspace').find('#video').remove();

			}
			else {
				windowMaker(response.html);
			}
			$.each(response.artist, function(i,v) {
				$('.music_artist[artist="' + v.artist + '"][path="' + v.path + '"]').attr('active', 'yes');
			});
			$.each(response.album, function(i,v) {
				$('.music_album[album="' + v.album + '"][path="' + v.path + '"]').attr('active', 'yes');
			});
			
			if (state == 1) {
				var v = document.getElementById('video');
				v.src = src;
				var now = Date.now();
				currentTime = ((now - timestamp) / 1000) + currentTime;
				v.currentTime = currentTime;
				v.state = 1;
				var playing = $('.playing');
				var ts = $('#video').attr('thumb_style');
				$('#video').attr('style', ts).attr('type', nowPlaying['type']);
				if (nowPlaying['type'] == 'audio') {
					$('#video').hide();
				}
				else {
					$('#video').show();
				}
				tree.current_track = playing.attr('number');
				tree.sound.volume = master_volume;
				thisTrack(playing.closest('.track_item'));
				mediaMaker({ src: v.src, currentTime: v.currentTime, method: 'benign', timestamp: timestamp });
				var html = $('#music').parent().html();
				cacheSet({'app': 'music', 'context': 'content' },{ contents: html });
			}
			else {
				$('#video').hide();
			}
			var wind_id = $('#music').closest('.wind').attr('id');


			playing_now('update');

			$('#music_albums').scrollTop(albumScroll);
			$('#music_artists').scrollTop(artistScroll);
			musicInit('search');

			if (configOpen == true) {
				$('#music_configuration').show();
			}
			if (theatreMode == 'on') {
				theatreModeOn();
			}
		}
	});
}

function playing_now(movement) {
	var playing_scroll;
	if ($('.playing').is(':visible') > 0) {
		playing_scroll = ($('#music_files').scrollTop() - ( $('.playing').offset().top || 0 ) + $('#interface').height());
	}
	else {
		playing_scroll = "5 billion or something!";
	}
	if (movement != 'update') {
		musicAppointmentWriter('stop');
		$('.playing').removeClass('playing');
	}
	$('#track_' + tree.current_track).parent().addClass('playing');
	$('#track_' + tree.current_track).parent().addClass('playing');
	$('.track_description').each(function() { $(this).hide() });
	$('#track_' + tree.current_track).parent().find('.track_description').show();
	//$('#music_files').scrollTop(playing_scroll);

	return tree.current_track;

}

function musicFolderChecker() {
	var folders = [];
	$('.music_folder_toggle[status="on"]').each(function(i,v) {
		folders.push($(v).attr('location'));
	});
	return folders;
}

$(document).on('click', '.music_folder_toggle', function() {
	var b = $(this);
	var status = b.attr('status');
	var location = b.attr('location');
	var timestamp = Date.now();
	if (status == 'on') {
		status = 'off';
	}
	else {
		status = 'on';
	}
	$.ajax({
		url: '/music/folder_toggle',
		type: 'POST',
		data: { timestamp: timestamp, location: location, status: status },
		success: function(response) {
			b.attr('status', response);
			if (response == 'on') {
				b.css({'background-color': 'lightblue'});
			}
			else {
				b.css({'background-color': ''});
			}
			searchMusic();
		}
	});
});

$(document).on('click', '.music_lock', function() {
	if ($('#music').attr('unlock')) {
		$('#music').attr('unlock', undefined);
		settingDeleter({ 'app': 'music', 'setting': 'combo_unlock' });
		tree.sound = undefined;
		$('#music_search').val('');
		$('.music_artist').attr('active', 'no');
		$('.music_album').attr('active', 'no');
		var wt = $('.wind[app="video"]').attr('timestamp');
		closeWindow(wt);
		searchMusic();
	}
	else if ($('#music').is(':visible')) {
		$('#music').hide();
		$('#music_padlock').show();
	}
	else {
		$('#music').show();
		$('#music_padlock').hide();
	}
});

$(document).on('click', '#music_cancel_padlock', function() {
	$('#music').show();
	$('#music_padlock').hide();
});

$(document).on('click', '.music_shuffle', function() {
	var shuffle = $(this).attr('enabled');
	if (shuffle == 'on') {
		shuffle = 'off';
	}
	else {
		shuffle = 'on';
	}
	$(this).attr('enabled', shuffle);

	var list = [];
	$.each(tree.files, function(i,v) {
		list.push($(v).text());
	});
	searchMusic({ list: list, same_order: 0, new_settings: { 'shuffle': shuffle } });

});

$(document).on('click', '#music_layout_select', function() {
	var layout = $(this).val();
	var list = [];
	$.each(tree.files, function(i,v) {
		list.push($(v).text());
	});
	searchMusic({ list: list, same_order: 1, new_settings: { 'layout': layout } });

});


$(document).on('change', '#music_library_select', function() {
	var library = $(this).val();
	settingSetter({ app: 'music', setting: 'library', value: library });
	searchMusic({  });
});

$(document).on('click', '.music_repeat', function() {
	var repeat = $(this).attr('enabled');
	if (repeat == 'on') {
		repeat = 'off';
	}
	else {
		repeat = 'on';
	}
	settingSetter({ app: 'music', setting: 'repeat', value: repeat });
	$(this).attr('enabled', repeat);
});


$(document).on('click', '.music_audio_output_select', function() {
	var output = $(this).val();
	var state = $(this).attr('state');
	var file = tree.songs[0].file;
	var seek = tree.sound.currentTime;
	if (state == 'on') {
		state = 'off';
		if (output != 'me' && output != 'srv') {
			var timestamp = Date.now();
			var tr = { volume: master_volume, timestamp: timestamp, method: 'transmitter', music_data: tree.songs[0], file: file, domain: output, toggle: 'off', seek: seek };
			var jtr = JSON.stringify(tr);
			ws['music'].send(jtr);
		}
	}
	else {
		state = 'on';
		if (output != 'me' && output != 'srv') {

			if (tree.sound.state == 1) {
				var timestamp = Date.now();
				var tr = { volume: master_volume, timestamp: timestamp, method: 'transmitter', music_data: tree.songs[0], file: file, domain: output, toggle: 'on', seek: seek };
				var jtr = JSON.stringify(tr);
				ws['music'].send(jtr);
			}
		}
	}
	
	$(this).attr('state', state);
	$.ajax({
		url: '/music/audio_output_select',
		type: 'POST',
		data: { state: state, output: output },
		success: function(response) {
			mao = response;
			if (mao['me'] == 'on') {
				tree.sound.volume = master_volume;
			}
			if (mao['me'] == 'off') {
				tree.sound.volume = 0.0000001;
			}
		}
	});



});

$(document).on('click', '#music_configuration_toggle', function() {
	var mc = $('#music_configuration');
	var remote_uuid = $('#music_configuration').attr('remote_uuid');
	if (mc.is(':visible')) {
		mc.hide();
	}
	else {
		mc.show();
		$.ajax({
			url: '/music/configuration',
			type: 'GET',
			data: { },
			success: function(response) {
				mc.html(response.html);
				volumeChecker();
				var z_index = $('#interface').css('z-index') + 1;
				mc.css({ 'z-index': z_index });
			}
		});
	}
});

$(document).on('click', '.all_music', function() {
	var library = $(this).attr('library');
	var enabled = $(this).attr('enabled');
	if (enabled == 'yes') {
		enabled = 'no';
	}
	else {
		enabled = 'yes';
	}
	$(this).attr('enabled', enabled);
	var setting = 'all_' + library;
	var new_settings = {};
	new_settings[setting] = enabled;
	searchMusic({ 'new_settings': new_settings });
});










