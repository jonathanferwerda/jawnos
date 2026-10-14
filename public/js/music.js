var mao = {};
var misses = {};
var music_muted = false;
// Play/pause glyphs follow the selected icon set; the music window stashes the
// resolved paths on #play_logo (see apps/music/music.html.ep).
function jawnosPlayIcon() { var s = $('#play_logo').attr('play_icon'); return s || '/icons/play.jpg'; }
function jawnosPauseIcon() { var s = $('#play_logo').attr('pause_icon'); return s || '/icons/pause.jpg'; }

// The local element is this machine's own output: audible whenever the 'me'
// output is on (which is also the default when the setting has no 'me' key at
// all), silent when it is explicitly off. The volume is deliberately dropped
// for the audio-autoplay handshake and for each track change, so every path
// that starts or resumes playback has to restore it through here - the one that
// forgot played the track muted (tapping a paused picture, or re-opening the
// app on a track that was already loaded).
function musicLocalVolume() {
	if (music_muted || mao['me'] == 'off') { return 0; }
	return master_volume;
}
function musicVolumeApply() {
	if (tree && tree.sound) { tree.sound.volume = musicLocalVolume(); }
}
// Is the window wearing the phone's own draw? The template says so on #music
// (see apps/music/music.html.ep): the shelves are one-line strips and the list
// runs from under them to the player, all of it inline. The desktop's geometry
// must not be laid over that, so the saved shelf sizes and the shelf drag
// handles stand down - and because the mark is the markup's, the two can never
// disagree about which draw is showing.
function musicPhoneLayout() {
	return $('#music').attr('phone_layout') == 'yes';
}
// The rendered window contents are cached server-side and reused on the next
// open; key that cache to the code revision, so a template change (which ships
// with a version bump) is never served stale - the tools toggle went missing
// this way once already.
var lastMusicRawHtml, lastMusicCacheHtml;
// The window is cached server-side and replayed on the next open, so strip the
// player-specific parts before storing it: the playing row, the inline player
// snapshot, the media source and the title. They all come back from the live
// player cache on restore - a frozen copy made the browser load the old source
// first and showed a stale row until the restore caught up. Nothing is sent
// unless the stored shell actually changed.
function musicContentCache(html) {
	if (html == lastMusicRawHtml) { return; }
	lastMusicRawHtml = html;
	// innerHTML never runs scripts; $('<div/>').html(html) would execute the
	// window's inline <script> a second time
	var doc = document.implementation.createHTMLDocument('music_cache');
	doc.body.innerHTML = html;
	var shell = $(doc.body);
	shell.find('.playing').removeClass('playing holla');
	shell.find('#music_player_data').empty();
	shell.find('video.media_out').removeAttr('src');
	shell.find('#video_subtitles').removeAttr('src');
	// the visualiser is live state too: the canvas and the video it is played
	// into are rebuilt by music.js, so the shell stores them bare
	shell.find('.media_visualizer, .media_visual_media').removeAttr('style').removeAttr('width').removeAttr('height').removeAttr('src');
	shell.find('[id$="_full_title"]').text('');
	shell.find('#play_logo').each(function() { var el = $(this), p = el.attr('play_icon'); if (p) { el.attr('src', p); } });
	shell = shell.html();
	if (shell == lastMusicCacheHtml) { return; }
	lastMusicCacheHtml = shell;
	cacheSet({ 'app': 'music', 'context': 'content', 'subcontext': (typeof jawnos_version != 'undefined' ? jawnos_version : '') }, { contents: shell });
}
// The mute button carries both glyphs; which one shows follows the same rule as
// the volume itself: muted when the user muted it or the machine's own output is
// switched off in the configuration panel.
function updateMusicMuteIcon() {
	var button = $('#music_mute');
	if (!button.length) { return; }
	var muted = (music_muted || mao['me'] == 'off');
	button.attr('src', muted ? button.attr('mute_icon') : button.attr('speaker_icon'));
	button.attr('muted', muted ? 'yes' : 'no');
}
$(document).on('ready', function() { 
	treeMaker();
});
$(document).on('click', '#music_toggle', function() {
	musicToggle();
});

function musicToggle(files, same_order) {
	var url = '/manager/music';
	var timestamp = Date.now();
	var jmiss = JSON.stringify(misses);
	if ($('#music').length == 0 || files ) {
		var jfiles;
		if (files) {
			jfiles = JSON.stringify(files);
		}
		$.ajax({
			url: url,
			type: 'GET',
			data: { window_maker: 'yes', timestamp: timestamp, misses: jmiss, files: jfiles, same_order: same_order ? 1 : 0 },
			success: function(response) {

				var window_id = windowMaker(response);

				// a handed-over list (the guide's play, a folder's play) skips the
				// saved track's restore: musicInit('files') brings the volume, mute
				// and layout back but leaves the player to the list about to start
				musicInit(files ? 'files' : undefined);
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
		// not a silent start: restore the machine's own output level, or a track
		// that is already loaded plays back at the audio-handshake volume when the
		// app is re-opened
		musicVolumeApply();
	}
	// The window contents can be served from the server-side cache, which freezes
	// the player snapshot that was inlined when it was written. Trusting that copy
	// restored the first track at 0:00 after a refresh, so fetch the live player
	// cache before restoring. (The old $().load() here was async, so the read on
	// the next line always saw the frozen copy.)
	var jpd = $('#music_player_data').text();
	if (method != 'search') {
		try {
			var fresh = await $.ajax({ url: '/manager/cache_get?app=music&context=player&json=yes', dataType: 'text' });
			if (isJson(fresh)) { jpd = fresh; $('#music_player_data').text(jpd); }
		}
		catch (e) { /* keep the inlined copy if the fetch fails */ }
	}
	if (isJson(jpd) && method != 'search') {

		var pd = JSON.parse(jpd);
		// the level and mute the player was last left at; a cached near-zero is the
		// old autoplay-handshake value, so it is ignored
		if (pd.volume && pd.volume >= 0.05) { master_volume = pd.volume; }
		music_muted = !!pd.muted;
		$('#music_volume').val(master_volume);
		updateMusicMuteIcon();
		musicVolumeApply();
		$('#video').attr('theatre_mode', pd.theatre_mode);
		$('#video').attr('type', pd.type);
		// the drawing the player was left on; musicVisualApply below puts it back
		musicVisual.mode = pd.visualization || 'none';

		// pick the saved track first, so thisTrack slices tree.songs and mediaMaker
		// then loads THAT track - mediaMaker reads tree.songs[0] and ignores the file
		// it is handed, so running it before this loaded the first track instead.
		// A window opened on a handed-over list (the guide's play, a folder's play)
		// must NOT bring the saved track back: the caller is about to start the list,
		// and the restore used to override it - that is how "watch Star Trek" played
		// whatever was last on. Volume, mute, theatre and layout still come back;
		// only the track does not.
		if (method != 'files') {
			$('.music_file').removeClass('playing');
			var mf = pd.file ? $('.music_file[file="' + pd.file + '"]') : $();
			mf.addClass('playing');
			var playing = $('.playing');
			tree.current_track = playing.attr('number');
			thisTrack(playing.closest('.track_item'));
			$('#video_full_title').text(playing.find('.full_title').text());

			// only a saved track is restored: a first-ever open (no player cache) must
			// not start playing on its own
			if (pd.file) {
				mediaMaker({ file: pd.file, currentTime: pd.currentTime, method: 'restore', timestamp: Date.now(), state: pd.state, });
				if (method != 'search') {
					tree.sound.currentTime = pd.currentTime;
				}
				tree.sound.state = pd.state;
			}
		}
		$('#music_player_data').text(jpd);

		tree.sound.textTracks[0].mode = $('#video_subtitle_toggle').attr('status');

		if ($('#video').attr('type') == 'audio') {
			$('#video').hide();
		}
		if (pd.state == 0 && method != 'search' && method != 'files') {
			tree.sound.pause();
		}
		if (pd.resizes && !musicPhoneLayout()) {
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
		musicVisualApply();
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

	if (!musicPhoneLayout()) {
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
	}
	var mc = $('#music_configuration');
	if (mc.is(':visible')) {
		var z_index = $('#interface').css('z-index') + 1;
		mc.css({ 'z-index': z_index });
	}
}
function playerCacheSaver(type) {
	var timestamp = Date.now();
	var jpd;
	if (timestamp - tree.lastCache >= 5000) {
		var unlocked = 0;
		if ($('#music').attr('unlock')) { unlocked = 1; }
		var playerData = { 
			number: tree.current_track, 
			'currentTime': tree.sound.currentTime, 
			file: tree.songs[0].file, 
			volume: master_volume, 
			muted: music_muted, 
			state: tree.sound.state, 
			theatre_mode: $('#video').attr('theatre_mode'), 
			unlocked: unlocked,
			resizes: {
				music_albums: { bottom: $('#music_albums').css('top'), height: $('#music_albums').height() },
				music_artists: { bottom: $('#music_artists').css('top'), height: $('#music_albums').height() },
				music_files: { top: $('#music_files').css('top'), height: $('#music_files').height() }
			},
			type: $('#video').attr('type'),
			visualization: musicVisual.mode,
			method: 'playerCache',
			subtitle_mode: tree.sound.textTracks[0].mode
		};
		jpd = JSON.stringify(playerData);


		if (type == 'ajax' || ws['music'].readyState != 1) {
			cacheSet({ 'app': 'music', 'context': 'player'}, playerData);
			musicContentCache($('#music').parent().html());
		}
		else {
			ws['music'].send(jpd);
		}
		$('#music_player_data').text(jpd);
		tree.lastCache = timestamp;
	}
	return jpd;
}

function treeMaker() {
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
	for (n = 0; n <= tree.files.length - 1; n++) {
		if (tree.files[n].textContent !== undefined) {
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
			// 'benign' leaves the media untouched (a search re-render must not restart
			// the track). 'restore' is the page-load path: it loads the saved track and
			// resumes when the player was left playing, overriding any stale src the
			// served window carried, but does not re-announce it remotely.
			if (method != 'benign') {

				if (tree.songs[0].type == 'audio') {
					$('#music_library').show();
					$('#video').hide();
					$('#video').attr('type', 'audio');
					$('#album_cover').show();
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
				tree.sound.html5 = true;
				tree.sound.playbackRate = 1;
				tree.sound.currentTime = time || 0;
				tree.sound.queued = 0;
				// the seek bar is only redrawn by the playing interval, which does not run
				// while paused, so a paused restore would otherwise leave it sitting at 0
				// even though the track is at its saved position
				tree.sound.onloadedmetadata = function() {
					var m = $('#video').attr('miss');
					var bar = m ? $('#' + m + '_position') : $();
					if (bar.length && tree.sound.duration) {
						bar.val(tree.sound.currentTime / tree.sound.duration * 100);
					}
				};
				if (data['state'] != 0) {
					// the play() above runs before load()/the new src and is aborted by them,
					// so start here instead, once the source is in place. A refresh has no
					// user gesture yet and browsers only autoplay a muted element, so a
					// restore starts muted; onplaying lifts that again.
					if (method == 'restore') { tree.sound.muted = true; }
					tree.sound.play();
				}
				if (method != 'restore') {
					remoteTrackToggle({
						file: file,
						toggle: 'on',
						seek: tree.sound.currentTime
					});
				}
			}
			if ($('#video').attr('theatre_mode') == 'on') {
				theatreModeOn();
			}
			else {
				theatreModeOff();
			}
			tree.sound.onplaying = function() {
				if (method == 'restore') { tree.sound.muted = false; }
				tree.sound.state = 1;
				musicVolumeApply();
				var total = tree.sound.duration;
				$('#progress_bar').attr('max', total);
					var endsong = tree.sound.duration;
					$('#total').text(endsong);


					
					var app = tree.songs[0].app;
					
					if (method != 'benign' && method != 'restore') {
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
						// subtitles are there when the track has a usable source, not when its
						// cues happen to be parsed: after a search re-render the cues arrive a
						// beat later, and the button used to be hidden in that beat and the
						// mode forced off
						var subtitle_track = document.getElementById('video_subtitles');
						var subtitle_text = tree.sound.textTracks && tree.sound.textTracks[0];
						var subtitle_cues = subtitle_text && subtitle_text.cues;
						var subtitle_ready = !!(subtitle_track && subtitle_track.getAttribute('src') && (subtitle_track.readyState < 2 || (subtitle_cues && subtitle_cues.length)));
						if (subtitle_ready && subtitle_text) {
							$('#video_subtitle_toggle').show();
							subtitle_text.mode = $('#video_subtitle_toggle').attr('status') == 'showing' ? 'showing' : 'hidden';
						}
						else {
							$('#video_subtitle_toggle').hide();
							if (subtitle_text) { subtitle_text.mode = 'hidden'; }
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
					tree.sound.state = 0;
			
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
	musicContentCache(html);
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
				var timestamp = Date.now();
				var tr = { queuing: data['queuing'], timestamp: timestamp, volume: master_volume, method: 'transmitter', music_data: music_data, file: file, domain: i, toggle: toggle, seek: seek };
				var jtr = JSON.stringify(tr);
				ws['music'].send(jtr);
				remoted = 1;
			}
		}
	});
	if (data['queuing'] != 1 && remoted == 0) {
		musicVolumeApply();
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

// Does the player's picture take the bigger of its two styles? The theatre is
// the obvious yes; a full screen is one too - a player that fills the screen
// should not leave its picture in the corner.
function musicPictureBig() {
	if ($('#video').attr('theatre_mode') == 'on') { return true; }
	var v = document.getElementById('video');
	var fs = document.fullscreenElement || document.webkitFullscreenElement;
	return !!(fs && v && (fs == v || fs.contains(v)));
}

// In and out of fullscreen the player's own picture is put back where it
// belongs; the visualiser's picture is placed by its own frame loop.
$(document).on('fullscreenchange webkitfullscreenchange', function() {
	var v = $('#video');
	if (v.length && v.attr('type') == 'video' && v.attr('theatre_mode') != 'on') {
		v.attr('style', v.attr(musicPictureBig() ? 'big_style' : 'thumb_style'));
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
		// the interface already fades in and out with the theatre controls (see
		// the video include), so the gear only has to stop being hidden here
		$('#interface').hide();
		$('#music_padlock_toggle').hide();
		$('#music_album_cover').hide()
	}
}

function theatreModeOff() {
	$('#music_library').show();
	$('#music').css({'background-color': $('#music').attr('background_colour')});
	if ($('#video').attr('type') == 'video') {
		// the picture goes back to its corner - unless the player itself is
		// filling the screen, where a corner thumbnail is not what is wanted
		var style = $('#video').attr(musicPictureBig() ? 'big_style' : 'thumb_style');
		$('#video').attr('style', style);
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
	// the appointment reads album - artist - track, and a part that is not there
	// is left out rather than written as 'undefined'
	var words = [];
	if (album != undefined && album != '') { words.push(album); }
	if (artist != undefined && artist != '') { words.push(artist); }
	if (song != undefined && song != '') { words.push(song); }
	words = words.join(' - ');
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

$(document).on('click', '.music_file_fetch_home', function () {
	var b = $(this);
	$.ajax({
		url: '/manager/folders/archive/fetch',
		type: 'POST',
		data: { path: b.attr('file'), remote_uuid: b.attr('remote_uuid') },
		success: function (response) {
			// dimmed once it is on the queue; the folders app's panel shows it
			if (response && response.status == 'ok') { b.css({ 'opacity': 0.4 }); }
		}
	});
});

$(document).on('click', '#play', function() {
	if (tree.sound.src == '') {
		mediaMaker({ file: tree.songs[0].file });
	}
	else if (tree.sound.paused) {
		tree.sound.muted = false;
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
	musicContentCache(html);
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
// The volume slider sets the level to play back at; mute silences without losing
// it. Both go through musicVolumeApply() so the element and the icon agree.
$(document).on('input', '#music_volume', function() {
	master_volume = parseFloat(this.value);
	if (master_volume > 0) { music_muted = false; }
	musicVolumeApply();
	updateMusicMuteIcon();
});
$(document).on('click', '#music_mute', function() {
	music_muted = !music_muted;
	musicVolumeApply();
	updateMusicMuteIcon();
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
	var library = data['library'];
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
	// a search swaps the track list; dim it (and drop the pointer) until the reply
	// lands, so the stale rows cannot be clicked in the meantime
	$('#music_files').addClass('music_loading');
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
			library: library,
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

			var v = document.getElementById('video');
			var timestamp = Date.now();
			var state = v.state;
			// A search only ever changes the library lists (and, on a library
			// switch, the configuration panel). Swapping just those keeps the
			// player and the rest of the window untouched: no flash, and the
			// <video> element is never destroyed, so playback is not interrupted.
			var fragment = $('<div></div>').html(response.html);
			var in_place = fragment.find('#music_files').length > 0 && $('#music_files').length > 0;
			// a full render would tear the <video> down; park a loaded one first
			var keep_video = !!v.src;
			var parking = $('#temporary_workspace');
			if (!parking.length) {
				parking = $('<div style="display:none;"></div>').appendTo('body');
			}

			treeMaker();

			var configOpen = $('#music_configuration').is(':visible');
			if (in_place) {
				// the list elements come back fresh, so musicInit rebuilds their
				// jQuery UI resizable state below
				$('#music_artists').replaceWith(fragment.find('#music_artists'));
				$('#music_albums').replaceWith(fragment.find('#music_albums'));
				$('#music_files').replaceWith(fragment.find('#music_files'));
				var new_music = fragment.find('#music');
				var new_unlock = new_music.attr('unlock');
				if (new_unlock !== undefined) {
					$('#music').attr('unlock', new_unlock);
				}
				// the configuration panel carries the library's own controls and
				// its remote_uuid, so it moves with a library switch
				if (fragment.find('#music_configuration').length) {
					$('#music_configuration').replaceWith(fragment.find('#music_configuration'));
				}
			}
			else {
				if (keep_video) {
					// out of the window before the render...
					parking.append(v);
				}
				windowMaker(response.html);
				if (keep_video) {
					// ...and back into the fresh .media_window, replacing the empty
					// <video> the render produced
					var fresh = $('#music').find('#video');
					if (fresh.length) {
						fresh[0].replaceWith(v);
					}
					else {
						$('#music').find('.media_window').append(v);
					}
				}
			}
			$.each(response.artist, function(i,v) {
				$('.music_artist[artist="' + v.artist + '"][path="' + v.path + '"]').attr('active', 'yes');
			});
			$.each(response.album, function(i,v) {
				$('.music_album[album="' + v.album + '"][path="' + v.path + '"]').attr('active', 'yes');
			});
			
			if (state == 1) {
				var v = document.getElementById('video');
				v.state = 1;
				var playing = $('.playing');
				// the media element is the one that has been playing all along, so
				// its src, position and style need no restore
				$('#video').attr('type', nowPlaying['type']);
				if (nowPlaying['type'] == 'audio') {
					$('#video').hide();
				}
				else {
					$('#video').show();
				}
				tree.current_track = playing.attr('number');
				musicVolumeApply();
				thisTrack(playing.closest('.track_item'));
				mediaMaker({ src: v.src, currentTime: v.currentTime, method: 'benign', timestamp: timestamp });
				var html = $('#music').parent().html();
				musicContentCache(html);
			}
			else {
				$('#video').hide();
			}
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
		},
		complete: function() {
			// however the search ended (even a dropped connection), put the cursor
			// and the track list back
			$('body').css({ 'cursor': 'auto' });
			$('#music_files').removeClass('music_loading');
		}
	});
}

function playing_now(movement) {
	if (movement != 'update') {
		musicAppointmentWriter('stop');
		$('.playing').removeClass('playing');
	}
	$('#track_' + tree.current_track).parent().addClass('playing');
	$('.track_description').each(function() { $(this).hide() });
	$('#track_' + tree.current_track).parent().find('.track_description').show();

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

$(document).on('click', '.music_archive_toggle', function() {
	var b = $(this);
	var status = b.attr('status');
	if (status == 'on') {
		status = 'off';
	}
	else {
		status = 'on';
	}
	$.ajax({
		url: '/music/archive_toggle',
		type: 'POST',
		data: { timestamp: Date.now(), status: status },
		success: function (response) {
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
	// clear the artist/album picks: they were folds of the old library, and
	// their stored paths would be scanned (and found empty) at the new one
	$('.music_album').attr('active', 'no');
	$('.music_artist').attr('active', 'no');
	// the choice goes with the search, in one request - written separately it
	// raced the search, and the search could relay to the old machine again
	searchMusic({ library: library });
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
			musicVolumeApply();
			updateMusicMuteIcon();
		}
	});



});

$(document).on('click', '#music_configuration_toggle', function() {
	var mc = $('#music_configuration');
	var remote_uuid = mc.attr('remote_uuid');
	if (mc.is(':visible')) {
		mc.hide();
	}
	else {
		mc.show();
		$.ajax({
			url: '/music/configuration',
			type: 'GET',
			// name the loaded remote library so the panel can show it as the
			// current selection instead of losing it
			data: { remote_uuid: remote_uuid },
			success: function(response) {
				mc.html(response.html);
				volumeChecker();
				// a computed z-index of 'auto' used to become 'auto1' here, which
				// browsers ignore - the panel then hid behind a theatre picture
				var z_index = (parseInt($('#interface').css('z-index')) || 0) + 1;
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

// ---- the visualiser ---------------------------------------------------------
//
// An audio file has no picture, so the player draws the sound instead - on a
// canvas that is never itself seen: the drawing is handed to a muted video as
// its stream (canvas.captureStream), and that video wears the player's own
// picture styles. The sound's picture therefore reaches the player the way a
// video track's does: the corner thumbnail while the library is up, the whole
// player in the theatre or in fullscreen. The four drawings are the dropdown in
// the tools panel (None leaves the player to its album cover); the choice rides
// in the player cache like theatre_mode.
//
// The sound is tapped with the Web Audio API. An element can only be captured
// once, so the tap is made lazily (the dropdown is the user gesture that also
// lets the context start) and then kept for the page: the graph is a
// pass-through, source -> analyser -> destination, and the element still
// behaves as it normally would, so volume, mute, seeking and src changes all
// still do what they did - what you hear is what is drawn.

var musicVisual = {
	mode: 'none',
	ctx: null,
	el: null,
	source: null,
	analyser: null,
	freq: null,
	raf: 0,
	last: 0,
	resumeAt: 0,
	canvas: null,
	feedCanvas: null,
	stream: null,
	painted: null,
	peaks: [],
	dots: [],
	dotW: 0,
	dotH: 0,
	art: null,
	st: null
};

function musicVisualState() {
	if (!musicVisual.st) {
		musicVisual.st = { t: 0, bass: 0.05, mid: 0.05, treble: 0.05, level: 0.05, centroid: 0.1, avg: 0.05, beat: false, lastBeat: -1, hue: 0 };
	}
	return musicVisual.st;
}

// Fullscreen for the player, the way the picture needs it: a video track is the
// video element as ever; anything else takes the whole player, so the sound's
// picture (the visualiser's video) and the controls - the dropdown that chooses
// it lives there - come along.
function musicPlayerFullscreen() {
	var v = document.getElementById('video');
	if (!v) { return; }
	var target = v;
	if (v.getAttribute('type') == 'video') {
		$(v).show();
	}
	else {
		$(v).hide();
		var miss = v.getAttribute('miss');
		var container = miss ? document.getElementById(miss + '_container') : null;
		if (container) { target = container; }
	}
	var p = target.requestFullscreen ? target.requestFullscreen()
		: (target.webkitRequestFullscreen ? target.webkitRequestFullscreen() : null);
	if (p && p.catch) { p.catch(function () {}); }
}

// The analyser, made on first use and kept for the page: an element can only be
// captured once, and the graph has to stay in place or the sound goes with it.
function musicVisualAnalyser() {
	var el = document.getElementById('video');
	if (!el) { return null; }
	if (!musicVisual.ctx) {
		var Ctor = window.AudioContext || window.webkitAudioContext;
		if (!Ctor) { return null; }
		try { musicVisual.ctx = new Ctor(); } catch (e) { return null; }
	}
	if (musicVisual.el !== el) {
		// a re-opened window hands back a fresh element; the old tap is spent
		if (musicVisual.source) { try { musicVisual.source.disconnect(); } catch (e) {} }
		musicVisual.source = null;
		musicVisual.analyser = null;
		try {
			musicVisual.source = musicVisual.ctx.createMediaElementSource(el);
			musicVisual.analyser = musicVisual.ctx.createAnalyser();
			musicVisual.analyser.fftSize = 2048;
			musicVisual.analyser.smoothingTimeConstant = 0.82;
			musicVisual.source.connect(musicVisual.analyser).connect(musicVisual.ctx.destination);
			musicVisual.el = el;
		}
		catch (e) {
			musicVisual.source = null;
			return null;
		}
	}
	if (musicVisual.ctx.state == 'suspended') {
		// the dropdown is the usual gesture that lets the context start; this is
		// the retry for one that was interrupted (a phone call, say)
		var now = Date.now();
		if (now - musicVisual.resumeAt > 1000) {
			musicVisual.resumeAt = now;
			var p = musicVisual.ctx.resume();
			if (p && p.catch) { p.catch(function () {}); }
		}
	}
	return musicVisual.analyser;
}

// One moment of the sound: the band levels (0..1), where its weight sits (the
// centroid), a beat, and the smoothed versions the drawings are made from. With
// nothing to hear the levels idle along a slow breath, so a paused player is
// calm rather than dead.
function musicVisualSample(analyser, dt) {
	var st = musicVisualState();
	var bass = 0, mid = 0, treble = 0, level = 0, centroid = st.centroid;
	if (analyser) {
		var f = musicVisual.freq;
		if (!f || f.length != analyser.frequencyBinCount) {
			f = musicVisual.freq = new Uint8Array(analyser.frequencyBinCount);
		}
		analyser.getByteFrequencyData(f);
		var n = f.length;
		var bEnd = Math.max(1, Math.round(n * 0.06));
		var mEnd = Math.max(bEnd + 1, Math.round(n * 0.35));
		var tEnd = Math.max(mEnd + 1, Math.round(n * 0.85));
		var sum = 0, weighted = 0;
		for (var i = 0; i < n; i++) {
			sum += f[i];
			weighted += f[i] * i;
			if (i < bEnd) { bass += f[i]; }
			else if (i < mEnd) { mid += f[i]; }
			else if (i < tEnd) { treble += f[i]; }
		}
		bass = bass / (bEnd * 255);
		mid = mid / ((mEnd - bEnd) * 255);
		treble = treble / ((tEnd - mEnd) * 255);
		level = (bass * 1.35 + mid + treble * 0.75) / 3.1;
		centroid = sum > 0 ? (weighted / sum) / n : 0;
	}
	// the idle breath: a few percent of the scale, so nothing is ever still
	var idle = 0.05 + 0.028 * Math.sin(st.t * 0.8);
	if (level < 0.02) {
		level = idle;
		bass = idle;
		mid = idle * 0.8;
		treble = idle * 0.55;
	}
	var k = Math.min(1, dt * 7);
	st.bass += (bass - st.bass) * k;
	st.mid += (mid - st.mid) * k;
	st.treble += (treble - st.treble) * k;
	st.level += (level - st.level) * k;
	st.centroid += (centroid - st.centroid) * Math.min(1, dt * 2.5);
	// a beat is the bass standing over its own slow average
	st.avg = st.avg * 0.96 + st.bass * 0.04;
	st.beat = !!(st.bass > 0.12 && st.bass > st.avg * 1.3 && (st.t - st.lastBeat) > 0.22);
	if (st.beat) { st.lastBeat = st.t; }
	return st;
}

// The house fit: in the big picture the bitmap follows the canvas' css box, at
// most 2x for a retina screen and 1920 on the long edge - the picture is soft
// shapes, and a 4K screen should not cost 8M pixels a frame. The corner is a
// picture of its own shape, a small 16:9 band, so the thumbnail never inherits
// the shape of the whole player.
function musicVisualFit(canvas, big) {
	var w, h;
	if (big) {
		var cw = canvas.clientWidth || 0;
		var ch = canvas.clientHeight || 0;
		if (cw < 4 || ch < 4) { return false; }
		var scale = Math.min(window.devicePixelRatio || 1, 2);
		var long = Math.max(cw, ch);
		if (long * scale > 1920) { scale = 1920 / long; }
		w = Math.max(4, Math.round(cw * scale));
		h = Math.max(4, Math.round(ch * scale));
	}
	else {
		w = 480;
		h = 270;
	}
	if (canvas.width != w || canvas.height != h) {
		canvas.width = w;
		canvas.height = h;
		musicVisual.dots = [];
		musicVisual.peaks = [];
	}
	return true;
}

// The three pieces the drawing lives between: the player element (its miss names
// the other two), the canvas the drawing goes on, and the video it is played
// into.
function musicVisualElements() {
	var el = document.getElementById('video');
	var miss = el ? (el.getAttribute('miss') || '') : '';
	return {
		el: el,
		miss: miss,
		canvas: (miss && document.getElementById(miss + '_visualizer')) || null,
		feed: (miss && document.getElementById(miss + '_visual_media')) || null
	};
}

// The canvas as a picture: its stream, made once per canvas (a re-render hands
// back a fresh one, and a spent stream with it), given to the muted feed video.
function musicVisualFeed(parts) {
	if (!parts.canvas.captureStream) { return; }
	if (musicVisual.feedCanvas !== parts.canvas) {
		musicVisual.feedCanvas = parts.canvas;
		musicVisual.stream = parts.canvas.captureStream(30);
	}
	if (!musicVisual.stream) { return; }
	if (parts.feed.srcObject !== musicVisual.stream) {
		parts.feed.srcObject = musicVisual.stream;
		parts.feed.muted = true;
	}
	if (parts.feed.paused) {
		var p = parts.feed.play();
		if (p && p.catch) { p.catch(function () {}); }
	}
}

// The picture's dress and place, taken from the player's own two: the corner
// thumbnail while the library is up, the whole player in the theatre - or
// whenever the player itself fills the screen. The canvas wears the same style,
// so its bitmap matches what is on screen.
function musicVisualPlace(parts, big) {
	var style = parts.el.getAttribute(big ? 'big_style' : 'thumb_style') || '';
	var shown = style + 'display:block;';
	if (parts.feed.getAttribute('style') != shown) { parts.feed.setAttribute('style', shown); }
	if (parts.canvas.getAttribute('style') != style) { parts.canvas.setAttribute('style', style); }
}

function musicVisualStop() {
	if (musicVisual.raf) { cancelAnimationFrame(musicVisual.raf); musicVisual.raf = 0; }
	var feed = musicVisualElements().feed;
	if (feed && feed.style.display != 'none') { feed.style.display = 'none'; }
	musicVisual.canvas = null;
	musicVisual.painted = null;
	musicVisual.last = 0;
}

// Put the chosen drawing on the player: there is nothing to open and nothing to
// place here - the loop's first frame feeds the video and dresses it.
function musicVisualApply() {
	var parts = musicVisualElements();
	if (!parts.el || !parts.canvas || !parts.feed || musicVisual.mode == 'none') { musicVisualStop(); return; }
	if (!musicVisual.raf) { musicVisual.raf = requestAnimationFrame(musicVisualFrame); }
}

function musicVisualChoose(mode) {
	musicVisual.mode = mode || 'none';
	musicVisual.painted = null;
	musicVisualApply();
}

$(document).on('change', '.media_visualization', function() {
	musicVisualChoose(this.value);
	// the choice is part of the player cache, so it comes back with the track
	if (typeof tree != 'undefined' && tree && tree.songs && tree.songs.length) {
		tree.lastCache = 0;
		playerCacheSaver();
	}
});

function musicVisualFrame(ts) {
	musicVisual.raf = 0;
	var parts = musicVisualElements();
	if (!parts.el || !parts.canvas || !parts.feed || musicVisual.mode == 'none') {
		musicVisualStop();
		return;
	}
	if (parts.el.getAttribute('type') != 'audio') {
		// a video track brings its own picture: the drawing is put away and the
		// loop waits, so it comes straight back on its own
		musicVisualStop();
		musicVisual.raf = requestAnimationFrame(musicVisualFrame);
		return;
	}
	// a re-render hands back a fresh dropdown at its default; the drawing is the
	// truth, so the control is put back in step
	var select = document.getElementById(parts.miss + '_visualization');
	if (select && select.value != musicVisual.mode) { select.value = musicVisual.mode; }
	var big = musicPictureBig();
	musicVisualFeed(parts);
	musicVisualPlace(parts, big);
	if (!musicVisualFit(parts.canvas, big)) {
		// the player has no box to paint into (mid-resize, collapsed window):
		// there is nothing to paint, but the loop stays on for when it has one
		musicVisual.raf = requestAnimationFrame(musicVisualFrame);
		return;
	}
	musicVisual.canvas = parts.canvas;
	var g = parts.canvas.getContext('2d');
	if (!g) { musicVisualStop(); return; }
	if (musicVisual.painted != musicVisual.mode) {
		musicVisual.painted = musicVisual.mode;
		musicVisual.dots = [];
		musicVisual.peaks = [];
		musicVisual.art = null;
		g.clearRect(0, 0, parts.canvas.width, parts.canvas.height);
	}
	var now = ts / 1000;
	var dt = now - (musicVisual.last || now);
	musicVisual.last = now;
	if (dt <= 0) { dt = 0.001; }
	if (dt > 0.1) { dt = 0.1; }
	var st = musicVisualState();
	st.t += dt;
	musicVisualSample(musicVisualAnalyser(), dt);
	st.hue = (st.hue + dt * (14 + st.level * 160)) % 360;
	var draw = musicVisualDraw[musicVisual.mode];
	if (draw) { draw(g, parts.canvas.width, parts.canvas.height, st, dt); }
	musicVisual.raf = requestAnimationFrame(musicVisualFrame);
}

var musicVisualDraw = {

	// The spectrum: one bar per band, the hue walking with the pitch and a cap
	// that falls back so a hit is read twice.
	equalizer: function(g, w, h, st, dt) {
		var f = musicVisual.freq;
		var bars = Math.max(16, Math.min(110, Math.round(w / 16)));
		var gap = Math.max(1, Math.round(w * 0.003));
		var bw = (w - gap * (bars + 1)) / bars;
		g.fillStyle = '#000';
		g.fillRect(0, 0, w, h);
		if (musicVisual.peaks.length != bars) { musicVisual.peaks = new Array(bars).fill(0); }
		var have = f && f.length > 8;
		var step = have ? (f.length * 0.72) / bars : 0;
		var fall = h * dt;
		for (var i = 0; i < bars; i++) {
			var v = 0;
			if (have) {
				var a = Math.floor(i * step);
				var b = Math.max(a + 1, Math.floor((i + 1) * step));
				for (var k = a; k < b && k < f.length; k++) { if (f[k] > v) { v = f[k]; } }
			}
			v = v / 255;
			// the quiet bands keep a small life of their own
			var mag = Math.pow(Math.max(v, 0.015 + 0.012 * Math.sin(st.t * 1.4 + i * 0.6)), 1.2);
			var bh = Math.max(2, mag * (h - 6) * 0.96);
			var x = gap + i * (bw + gap);
			var hue = (st.hue + (i / bars) * 312) % 360;
			g.fillStyle = 'hsl(' + Math.round(hue) + ',92%,' + (40 + Math.round(mag * 26)) + '%)';
			g.fillRect(x, h - bh, bw, bh);
			musicVisual.peaks[i] = Math.max(musicVisual.peaks[i] - fall * (0.35 + v), bh);
			g.fillStyle = 'hsl(' + Math.round(hue) + ',96%,78%)';
			g.fillRect(x, h - musicVisual.peaks[i] - 3, bw, 3);
		}
	},

	// The dancers: a band of dots carried by the music, each its own colour,
	// with a low-alpha black in place of a clear so they carry tails. Now and
	// then one grows a face and legs - the music is lively; so are they.
	dots: function(g, w, h, st, dt) {
		var size = Math.min(w, h);
		if (musicVisual.dots.length == 0 || musicVisual.dotW != w || musicVisual.dotH != h) {
			musicVisual.dotW = w;
			musicVisual.dotH = h;
			musicVisual.dots = [];
			var count = Math.max(16, Math.min(64, Math.round(w * h / 46000)));
			for (var n = 0; n < count; n++) {
				musicVisual.dots.push({
					x: Math.random() * w,
					y: Math.random() * h,
					a: Math.random() * Math.PI * 2,
					wander: (Math.random() - 0.5) * 2.2,
					v: 0.05 + Math.random() * 0.13,
					r: size * (0.008 + Math.random() * 0.012),
					hue: Math.random() * 360,
					pulse: 0,
					face: false,
					life: 0
				});
			}
		}
		g.fillStyle = 'rgba(0,0,0,0.3)';
		g.fillRect(0, 0, w, h);
		var faces = 0;
		for (var c = 0; c < musicVisual.dots.length; c++) { if (musicVisual.dots[c].face) { faces++; } }
		for (var i = 0; i < musicVisual.dots.length; i++) {
			var d = musicVisual.dots[i];
			d.a += d.wander * dt * (0.5 + st.mid * 2.5);
			var sp = d.v * size * (0.35 + st.level * 2.6) * (1 + st.bass * 1.2);
			d.x += Math.cos(d.a) * sp * dt;
			d.y += Math.sin(d.a) * sp * dt;
			if (d.x < -d.r * 2) { d.x = w + d.r * 2; }
			if (d.x > w + d.r * 2) { d.x = -d.r * 2; }
			if (d.y < -d.r * 2) { d.y = h + d.r * 2; }
			if (d.y > h + d.r * 2) { d.y = -d.r * 2; }
			if (st.beat && d.pulse <= 0 && Math.random() < 0.35) {
				d.pulse = 0.9;
				d.a += (Math.random() - 0.5) * 0.6;
				if (!d.face && faces < 3 && Math.random() < 0.22) {
					d.face = true;
					d.life = 6 + Math.random() * 8;
					faces++;
				}
			}
			if (d.pulse > 0) { d.pulse = Math.max(0, d.pulse - dt * 1.4); }
			if (d.face) {
				d.life -= dt;
				if (d.life <= 0) { d.face = false; }
			}
			var r = d.r * (1 + st.bass * 1.9 + d.pulse * 0.8);
			var hue = (st.hue + d.hue) % 360;
			g.fillStyle = 'hsla(' + Math.round(hue) + ',95%,60%,0.16)';
			g.beginPath();
			g.arc(d.x, d.y, r * 2.6, 0, 6.2832);
			g.fill();
			g.fillStyle = 'hsla(' + Math.round(hue) + ',92%,62%,0.95)';
			g.beginPath();
			g.arc(d.x, d.y, r, 0, 6.2832);
			g.fill();
			if (d.face) { musicVisualDotFace(g, d, r, st); }
		}
	},

	// The tie-dye: soft rings and spiral arms over a slow fade, so the colour
	// builds like ink in water. The bass drives the swirl, the treble the
	// wobble, and the beat makes the whole thing breathe.
	psychedelic: function(g, w, h, st, dt) {
		// the fade is what makes it move: every frame leaves a ghost of itself
		g.globalCompositeOperation = 'source-over';
		g.fillStyle = 'rgba(0,0,0,0.06)';
		g.fillRect(0, 0, w, h);
		g.globalCompositeOperation = 'lighter';
		var cx = w / 2 + Math.sin(st.t * 0.17) * w * 0.13;
		var cy = h / 2 + Math.cos(st.t * 0.12) * h * 0.12;
		var size = Math.max(w, h);
		var spin = st.t * (0.2 + st.level * 1.5);
		var wobble = 0.08 + st.treble * 0.55;
		var arms = 6;
		g.lineCap = 'round';
		for (var arm = 0; arm < arms; arm++) {
			var base = spin + (arm / arms) * Math.PI * 2;
			var first = true;
			g.beginPath();
			for (var a = 0; a <= Math.PI * 3.2; a += 0.16) {
				var f = a / (Math.PI * 3.2);
				var rad = (0.06 + f * 0.54) * size;
				var wave = Math.sin(a * 2.3 + st.t * (0.8 + st.bass * 2.4) + arm) * wobble * rad * 0.35;
				var th = base + a + Math.sin(a * 1.7 + st.t * 0.4) * 0.3;
				var x = cx + Math.cos(th) * (rad + wave);
				var y = cy + Math.sin(th) * (rad + wave) * 0.94;
				if (first) { g.moveTo(x, y); first = false; }
				else { g.lineTo(x, y); }
			}
			var hue = (st.hue + arm * (360 / arms)) % 360;
			g.strokeStyle = 'hsla(' + Math.round(hue) + ',95%,55%,0.3)';
			g.lineWidth = size * (0.035 + st.bass * 0.045);
			g.stroke();
		}
		// rings on the beat, so the whole thing breathes
		var rings = 3;
		for (var r2 = 0; r2 < rings; r2++) {
			var rr = ((st.t * (0.06 + st.level * 0.25) + r2 / rings) % 1) * size * 0.7;
			g.strokeStyle = 'hsla(' + Math.round((st.hue + r2 * 70) % 360) + ',90%,60%,0.22)';
			g.lineWidth = size * 0.012 * (1 + st.bass * 2);
			g.beginPath();
			g.arc(cx, cy, rr, 0, 6.2832);
			g.stroke();
		}
		g.globalCompositeOperation = 'source-over';
	},

	// Modern Art: a stroke for the moment - the colour is where the sound sits
	// (weight low is warm, weight high is cool), the width is the bass, the
	// length the level - and every stroke is answered across the middle, so the
	// picture keeps a composition. The fade is a whisper, so the painting grows
	// rather than flickers.
	modern_art: function(g, w, h, st, dt) {
		var size = Math.max(w, h);
		g.globalCompositeOperation = 'source-over';
		g.fillStyle = 'rgba(0,0,0,0.012)';
		g.fillRect(0, 0, w, h);
		if (!musicVisual.art) {
			musicVisual.art = { x: Math.random() * w, y: Math.random() * h, a: Math.random() * Math.PI * 2, wait: 0 };
		}
		var art = musicVisual.art;
		art.wait -= dt;
		if (art.wait > 0) { return; }
		// a stroke every half second in quiet, ten a second at full tilt
		art.wait = (0.45 - Math.min(0.4, st.level * 0.5)) * (0.5 + Math.random());
		var hue = (st.centroid * 780 + st.hue * 0.2) % 360;
		var lum = 34 + Math.round(Math.min(1, st.level) * 38);
		var width = Math.max(2, size * (0.004 + st.bass * 0.04));
		var len = size * (0.02 + st.level * 0.14);
		art.a += (Math.random() - 0.5) * (0.4 + st.treble * 3);
		var nx = art.x + Math.cos(art.a) * len;
		var ny = art.y + Math.sin(art.a) * len;
		// the brush bends mid-stroke, the way a wrist does
		var mx = (art.x + nx) / 2 + (Math.random() - 0.5) * width * 2.5;
		var my = (art.y + ny) / 2 + (Math.random() - 0.5) * width * 2.5;
		g.strokeStyle = 'hsla(' + Math.round(hue) + ',85%,' + lum + '%,0.8)';
		g.lineWidth = width;
		g.lineCap = 'round';
		g.beginPath();
		g.moveTo(art.x, art.y);
		g.quadraticCurveTo(mx, my, nx, ny);
		g.stroke();
		g.beginPath();
		g.moveTo(w - art.x, art.y);
		g.quadraticCurveTo(w - mx, my, w - nx, ny);
		g.stroke();
		if (st.beat && Math.random() < 0.4) {
			// a bold gesture, the way a wrist makes one
			var bw = size * (0.02 + st.mid * 0.18);
			var bh = size * (0.015 + st.bass * 0.16);
			var bx = Math.random() * (w - bw);
			var by = Math.random() * (h - bh);
			g.fillStyle = 'hsla(' + Math.round((hue + 170) % 360) + ',80%,58%,0.16)';
			g.fillRect(bx, by, bw, bh);
			g.fillRect(w - bx - bw, by, bw, bh);
		}
		art.x = nx;
		art.y = ny;
		// the wrist does not leave the page
		if (art.x < 0 || art.x > w) { art.a = Math.PI - art.a; art.x = Math.max(0, Math.min(w, art.x)); }
		if (art.y < 0 || art.y > h) { art.a = -art.a; art.y = Math.max(0, Math.min(h, art.y)); }
	}
};

// A dot with a face: eyes that look where it is going, a smile that opens with
// the bass, and legs swinging as it goes.
function musicVisualDotFace(g, d, r, st) {
	var dx = Math.cos(d.a);
	var dy = Math.sin(d.a);
	var ex = -dy * r * 0.42;
	var ey = dx * r * 0.42;
	var er = Math.max(1.4, r * 0.24);
	var look = Math.min(1, 0.4 + st.level * 1.6) * r * 0.16;
	g.fillStyle = 'rgba(20,10,30,0.92)';
	g.beginPath(); g.arc(d.x + ex, d.y + ey, er, 0, 6.2832); g.fill();
	g.beginPath(); g.arc(d.x - ex, d.y - ey, er, 0, 6.2832); g.fill();
	g.fillStyle = '#fff';
	g.beginPath(); g.arc(d.x + ex + dx * look, d.y + ey + dy * look, er * 0.42, 0, 6.2832); g.fill();
	g.beginPath(); g.arc(d.x - ex + dx * look, d.y - ey + dy * look, er * 0.42, 0, 6.2832); g.fill();
	var mouth = r * (0.35 + st.bass * 0.45);
	g.strokeStyle = 'rgba(20,10,30,0.92)';
	g.lineWidth = Math.max(1.2, r * 0.14);
	g.beginPath();
	g.arc(d.x + dx * r * 0.15, d.y + dy * r * 0.15, mouth, Math.PI * 0.15, Math.PI * 0.85);
	g.stroke();
	var swing = Math.sin(st.t * 7 + d.hue) * r * 0.5;
	var lx = -dy * r * 0.5;
	var ly = dx * r * 0.5;
	g.beginPath();
	g.moveTo(d.x + lx, d.y + ly);
	g.lineTo(d.x + lx + swing, d.y + ly + r * 0.9);
	g.moveTo(d.x - lx, d.y - ly);
	g.lineTo(d.x - lx - swing, d.y - ly + r * 0.9);
	g.stroke();
	g.lineWidth = 1;
}










