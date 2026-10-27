// The Chat app's Rooms section: dial a junderground, see the door and the
// roster, grade it against the house's own people list, and join or leave.
// The switch URL and the house handle are the only settings; signing happens
// on the server, so the crest key never reaches this file.
(function () {
	function jgT(text) { return (typeof jawnosT === 'function') ? jawnosT(text) : text; }
	function jgEsc(value) { return $('<div>').text(value == null ? '' : String(value)).html(); }
	function jgTime(ts) { return ts ? new Date(ts * 1000).toLocaleString() : ''; }

	var jgPresence = {};
	var jgSockets = {};
	var jgNames = {};
	var jgCalls = {};
	var jgFriends = {};
	var jgVisits = {};

	// The signaling socket goes straight to the switch (the browser cannot ask
	// the Perl side to hold a WebSocket). The grant is short-lived and rides
	// the query string because a WebSocket handshake cannot carry a header.
	function jgWsBase() {
		var url = $.trim($('#jg_url').val() || '');
		if (!/^https?:\/\//i.test(url)) { return ''; }
		return url.replace(/\/+$/, '').replace(/^http/i, 'ws');
	}

	function jgSocketClose(handle, room) {
		var key = handle + '/' + room;
		var ws = jgSockets[key];
		delete jgSockets[key];
		jgMediaStop(handle, room);
		if (!ws) { return; }
		try { ws.close(); } catch (e) {}
	}

	function jgSocketOpen(handle, room, grant) {
		jgSocketClose(handle, room);
		var base = jgWsBase();
		if (!base || !grant) { return; }
		var key = handle + '/' + room;
		var ws;
		try {
			ws = new WebSocket(base + '/v1/rooms/' + encodeURIComponent(handle) + '/' +
				encodeURIComponent(room) + '/ws?grant=' + encodeURIComponent(grant));
		} catch (e) {
			$('#jg_status').text(jgT('The signaling channel did not open.'));
			return;
		}
		jgSockets[key] = ws;
		ws.onopen = function () { $('#jg_status').text(jgT('Signal open')); };
		ws.onmessage = function (event) {
			var msg;
			try { msg = JSON.parse(event.data); } catch (e) { return; }
			if (!msg || !msg.type) { return; }
			if (msg.type === 'hello') {
				$('#jg_status').text(jgT('Live') + ' · ' + (msg.peers || 1) + ' ' + jgT('in the room'));
				jgMediaStart(handle, room, msg);
			} else if (msg.type === 'error') {
				$('#jg_status').text(msg.error || '');
			} else if (msg.type === 'join') {
				jgOffer(handle, room, msg.from_jti);
				jgOpen(handle, room);
			} else if (msg.type === 'leave') {
				jgPeerClose(handle, room, msg.from_jti);
				jgOpen(handle, room);
			} else {
				jgHandleSignal(handle, room, msg);
			}
		};
		ws.onerror = function () { $('#jg_status').text(jgT('The signaling channel did not open.')); };
		ws.onclose = function () {
			if (jgSockets[key] === ws) {
				delete jgSockets[key];
				jgMediaStop(handle, room);
				jgVisitsStopAll();
			}
		};
	}

	function jgConfigLoad() {
		if (!$('#jg_panel').length) { return; }
		$.getJSON('/manager/junderground/config', function (r) {
			$('#jg_url').val(r.url || '');
			$('#jg_handle').val(r.handle || '');
			$('#jg_known').val(r.known || '');
			$('#jg_blacklist').val(r.blacklist || '');
			jgFriends = {};
			(r.friends || []).forEach(function (who) { jgFriends[who] = 1; });
		});
	}

	function jgConfigWhenReady(attempts) {
		if ($('#jg_panel').length) { jgConfigLoad(); return; }
		if (attempts > 0) { setTimeout(function () { jgConfigWhenReady(attempts - 1); }, 200); }
	}

	function jgPicks() {
		var picks = {};
		$('#jg_panel .jg_pick').each(function () {
			var value = $.trim($(this).val());
			if (value) { picks[$(this).attr('kind')] = value; }
		});
		return picks;
	}

	// The switch's identity for a value is a slug; its name is in the
	// administrator's language. Show the name, keep the slug for the room.
	function jgScope(constructs, names) {
		if (!constructs) { return ''; }
		names = names || {};
		return Object.keys(constructs).sort().map(function (key) {
			var value = constructs[key];
			var named = names[key] && names[key][value] ? names[key][value] : value;
			return key + '=' + named;
		}).join(' · ');
	}

	function jgNamesFrom(reply) {
		var map = {};
		var dial = reply.dial || {};
		var names = reply.names || {};
		Object.keys(dial).forEach(function (kind) {
			map[kind] = map[kind] || {};
			map[kind][dial[kind]] = names[kind] || dial[kind];
		});
		return map;
	}


	// ---- media ---------------------------------------------------------
	// A mesh: one RTCPeerConnection per other house in the room, audio only.
	// The switch relays SDP and ICE; nothing is stored here. A house with no
	// microphone still joins and listens, so the room is never silent-only.

	function jgKey(handle, room) { return handle + '/' + room; }
	function jgSafeId(jti) { return String(jti || '').replace(/[^A-Za-z0-9_-]/g, ''); }
	function jgCall(handle, room) { return jgCalls[jgKey(handle, room)]; }

	function jgSend(handle, room, msg) {
		var ws = jgSockets[jgKey(handle, room)];
		if (!ws || ws.readyState !== 1) { return false; }
		try { ws.send(JSON.stringify(msg)); return true; } catch (e) { return false; }
	}

	function jgAudioRoot() {
		var root = document.getElementById('jg_audio_root');
		if (!root) {
			root = document.createElement('div');
			root.id = 'jg_audio_root';
			root.style.display = 'none';
			document.body.appendChild(root);
		}
		return root;
	}

	function jgMediaStart(handle, room, hello) {
		var key = jgKey(handle, room);
		jgMediaStop(handle, room);
		var call = {
			self: hello.jti || '',
			selfSubject: hello.subject || '',
			ice: hello.ice_servers || [],
			pcs: {},
			pending: {},
			remote: {},
			tracked: {},
			answered: {},
			video: {},
			publish: {},
			captions: {},
			lines: {},
			sources: {},
			sourcePromises: {},
			published: {},
			camera: null,
			cameraPromise: null,
			stream: null,
			role: hello.role || '',
			share: 'camera',
			broadcastOn: false,
			broadcastStreams: {},
			broadcastTracks: {},
			remoteBroadcast: {},
			remotes: {},
			muted: false,
			ready: Promise.resolve(null)
		};
		jgCalls[key] = call;

		if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
			call.ready = navigator.mediaDevices.getUserMedia({ audio: true, video: false }).then(function (stream) {
				if (jgCalls[key] !== call) {
					stream.getTracks().forEach(function (t) { t.stop(); });
					return null;
				}
				call.stream = stream;
				jgRenderMedia(handle, room);
				return stream;
			}).catch(function () { return null; });
		}

		jgRenderMedia(handle, room);
	}

	function jgPeer(handle, room, jti) {
		var call = jgCall(handle, room);
		if (!call || !jti) { return null; }
		if (call.pcs[jti]) { return call.pcs[jti]; }

		var pc = new RTCPeerConnection({ iceServers: call.ice || [] });
		call.pcs[jti] = pc;

		pc.onicecandidate = function (e) {
			if (e.candidate) { jgSend(handle, room, { type: 'ice', candidate: e.candidate, to: jti }); }
		};

		pc.ontrack = function (e) {
			var call = jgCall(handle, room);
			if (call) { call.remote[jti] = e.streams[0]; }

			// A broadcast stream is announced ahead of its tracks; attach it to
			// the element the announcement made for it.
			var sid = (e.streams && e.streams[0]) ? e.streams[0].id : '';
			if (call && sid) {
				call.remotes[sid] = e.streams[0];
				var hook = null;
				document.querySelectorAll('[data-stream]').forEach(function (el) {
					if (el.getAttribute('data-stream') === sid) { hook = el; }
				});
				if (hook) {
					hook.srcObject = e.streams[0];
					var p = hook.play();
					if (p && p.catch) { p.catch(function () {}); }
					jgRenderMedia(handle, room);
					return;
				}
			}

			if (e.track && e.track.kind === 'video') {
				jgAttachVideo(handle, room, jti, e.streams[0]);
				e.track.onended = function () { jgDetachVideo(jti); };
			} else {
				var id = 'jg_audio_' + jgSafeId(jti);
				var audio = document.getElementById(id);
				if (!audio) {
					audio = document.createElement('audio');
					audio.id = id;
					audio.autoplay = true;
					jgAudioRoot().appendChild(audio);
				}
				audio.srcObject = e.streams[0];
				var playing = audio.play();
				if (playing && playing.catch) { playing.catch(function () {}); }
			}

			jgRenderMedia(handle, room);
			jgRestoreMedia(handle, room);
		};

		pc.onconnectionstatechange = function () { jgRenderMedia(handle, room); };
		return pc;
	}

	function jgAddTracks(handle, room, pc, stream, jti) {
		var call = jgCall(handle, room);
		if (!call || call.tracked[jti]) { return; }
		call.tracked[jti] = true;
		if (stream) {
			stream.getAudioTracks().forEach(function (track) { pc.addTrack(track, stream); });
		} else {
			pc.addTransceiver('audio', { direction: 'recvonly' });
		}
	}

	function jgOffer(handle, room, jti) {
		var call = jgCall(handle, room);
		if (!call || !jti || jti === call.self || call.pcs[jti]) { return; }
		call.ready.then(function (stream) {
			if (jgCalls[jgKey(handle, room)] !== call || call.pcs[jti]) { return; }
			var pc = jgPeer(handle, room, jti);
			if (!pc) { return; }
			jgAddTracks(handle, room, pc, stream, jti);
			pc.createOffer().then(function (offer) {
				return pc.setLocalDescription(offer);
			}).then(function () {
				jgSend(handle, room, { type: 'offer', sdp: pc.localDescription.sdp, to: jti });
			}).catch(function () {});
		});
	}

	function jgAnswer(handle, room, msg) {
		var call = jgCall(handle, room);
		if (!call || !msg.from_jti || !msg.sdp) { return; }
		var jti = msg.from_jti;
		call.ready.then(function (stream) {
			if (jgCalls[jgKey(handle, room)] !== call) { return; }
			var pc = jgPeer(handle, room, jti);
			if (!pc) { return; }
			if (!call.answered[jti]) {
				call.answered[jti] = true;
				jgAddTracks(handle, room, pc, stream, jti);
			}
			pc.setRemoteDescription({ type: 'offer', sdp: msg.sdp }).then(function () {
				return jgFlushIce(call, jti);
			}).then(function () {
				return pc.createAnswer();
			}).then(function (answer) {
				return pc.setLocalDescription(answer);
			}).then(function () {
				jgSend(handle, room, { type: 'answer', sdp: pc.localDescription.sdp, to: jti });
			}).catch(function () {});
		});
	}

	function jgAddIce(handle, room, msg) {
		var call = jgCall(handle, room);
		if (!call || !msg.from_jti || !msg.candidate) { return; }
		var jti = msg.from_jti;
		var pc = jgPeer(handle, room, jti);
		if (!pc) { return; }
		if (!pc.remoteDescription) {
			(call.pending[jti] = call.pending[jti] || []).push(msg.candidate);
			return;
		}
		pc.addIceCandidate(msg.candidate).catch(function () {});
	}

	function jgFlushIce(call, jti) {
		var pc = call.pcs[jti];
		var queue = call.pending[jti] || [];
		delete call.pending[jti];
		if (!pc) { return Promise.resolve(); }
		return Promise.all(queue.map(function (candidate) {
			return pc.addIceCandidate(candidate).catch(function () {});
		}));
	}

	function jgHandleSignal(handle, room, msg) {
		var call = jgCall(handle, room);
		if (!call) { return; }
		if (msg.type === 'offer') {
			jgAnswer(handle, room, msg);
		} else if (msg.type === 'answer') {
			var pc = jgPeer(handle, room, msg.from_jti);
			if (!pc) { return; }
			pc.setRemoteDescription({ type: 'answer', sdp: msg.sdp }).then(function () {
				return jgFlushIce(call, msg.from_jti);
			}).then(function () {
				jgBroadcastTo(handle, room, msg.from_jti);
			}).catch(function () {});
		} else if (msg.type === 'ice') {
			jgAddIce(handle, room, msg);
		} else if (msg.type === 'video') {
			if (msg.want === 'on') { jgVideoPublish(handle, room, msg.from_jti, msg.source); }
			else { jgVideoUnpublish(handle, room, msg.from_jti); }
		} else if (msg.type === 'broadcast') {
			jgBroadcastSeen(handle, room, msg);
		}
	}

	function jgPeerClose(handle, room, jti) {
		var call = jgCall(handle, room);
		if (!call || !jti) { return; }
		var pc = call.pcs[jti];
		delete call.pcs[jti];
		delete call.pending[jti];
		if (pc) { try { pc.close(); } catch (e) {} }
		var audio = document.getElementById('jg_audio_' + jgSafeId(jti));
		if (audio && audio.parentNode) { audio.parentNode.removeChild(audio); }
		jgRenderMedia(handle, room);
	}

	function jgMediaStop(handle, room) {
		var key = jgKey(handle, room);
		var call = jgCalls[key];
		if (!call) { return; }
		Object.keys(call.broadcastStreams || {}).forEach(function (id) {
			call.broadcastStreams[id].getTracks().forEach(function (track) { try { track.stop(); } catch (e) {} });
		});
		delete jgCalls[key];
		Object.keys(call.pcs).forEach(function (jti) {
			try { call.pcs[jti].close(); } catch (e) {}
		});
		if (call.stream) {
			call.stream.getTracks().forEach(function (track) { try { track.stop(); } catch (e) {} });
		}
		var root = document.getElementById('jg_audio_root');
		if (root) { root.innerHTML = ''; }
		$('#jg_media').empty();
	}

	function jgRenderMedia(handle, room) {
		var box = $('#jg_media').empty();
		var call = jgCall(handle, room);
		if (!call) { return; }
		var peers = Object.keys(call.pcs).length;
		var live = Object.keys(call.pcs).filter(function (jti) {
			return call.pcs[jti].connectionState === 'connected';
		}).length;
		$('<span class="jg_scope">')
			.text(jgT('Audio') + ': ' + live + ' / ' + peers)
			.appendTo(box);
		if (call.stream) {
			$('<button type="button" id="jg_mute" class="jg_mute" handle="' + jgEsc(handle) + '" room="' + jgEsc(room) + '">')
				.text(call.muted ? jgT('Unmute') : jgT('Mute'))
				.appendTo(box);
		} else {
			$('<span class="jg_scope">').text(jgT('Listening only')).appendTo(box);
		}
		$('<span class="jg_scope">').text(jgT('Sharing') + ':').appendTo(box);
		var share = $('<select id="jg_share_source" class="jg_person_source">')
			.attr({ handle: handle, room: room });
		jgSourceKinds().forEach(function (pair) {
			$('<option>').attr('value', pair[0]).text(pair[1]).appendTo(share);
		});
		share.val(call.share || 'camera').appendTo(box);
		$('<span class="jg_scope">').text(jgT('only when someone asks')).appendTo(box);
	}


	// ---- people --------------------------------------------------------
	// Every other house in the room gets a card. Video is pulled: the feed is
	// not sent until this side asks for it, and the publisher adds the camera
	// only to that peer's connection. Captions are made here, from the audio
	// that already arrived: transcribe, then translate into this house's
	// language through the Guide, and show it under the person.

	function jgSelf() { return $.trim($('#jg_handle').val() || '').toLowerCase(); }

	// hello names this house too; it is the better answer when the handle field
	// has not been filled in yet.
	function jgSelfFor(handle, room) {
		var call = jgCall(handle, room);
		return (call && call.selfSubject) ? call.selfSubject : jgSelf();
	}

	function jgPersonKey(jti) { return jgSafeId(jti); }

	function jgPersonCard(entry, handle, room) {
		var jti = entry.jti || '';
		var subject = entry.subject || '';
		var card = $('<div class="jg_person">').attr({ jti: jti, subject: subject });
		var initial = (subject || '?').slice(0, 1).toUpperCase();
		var head = $('<div class="jg_person_head">').appendTo(card);
		$('<span class="jg_person_avatar">').text(initial)
			.css('background', 'hsl(' + jgHue(subject) + ', 55%, 42%)').appendTo(head);
		$('<span class="jg_person_name">').text(subject || '?').appendTo(head);
		if (entry.ticketed) {
			$('<span class="jg_person_badge">').text(jgT('pass')).appendTo(head);
		}

		var actions = $('<div class="jg_person_actions">').appendTo(card);
		$('<button type="button" class="jg_person_btn jg_person_video_toggle">')
			.attr({ jti: jti, handle: handle, room: room })
			.text(jgT('Video')).appendTo(actions);
		$('<button type="button" class="jg_person_btn jg_person_caption_toggle">')
			.attr({ jti: jti, handle: handle, room: room })
			.text(jgT('Translate')).appendTo(actions);
		$('<button type="button" class="jg_person_btn jg_person_friend">')
			.attr('handle', subject)
			.text(jgFriends[subject] ? jgT('Friend') : jgT('Add friend')).appendTo(actions);

		$('<video class="jg_person_feed" playsinline autoplay></video>').appendTo(card);
		$('<div class="jg_person_streams"></div>').appendTo(card);
		$('<div class="jg_person_captions"></div>').appendTo(card);
		return card;
	}

	function jgHue(value) {
		var h = 0;
		var text = String(value || '');
		for (var i = 0; i < text.length; i++) { h = (h * 31 + text.charCodeAt(i)) % 360; }
		return h;
	}

	function jgAttachVideo(handle, room, jti, stream) {
		var card = $('.jg_person[jti="' + jgSafeId(jti) + '"]');
		var video = card.find('video.jg_person_feed').first();
		if (!video.length) { return; }
		video[0].srcObject = stream;
		video.addClass('on');
		var playing = video[0].play();
		if (playing && playing.catch) { playing.catch(function () {}); }
	}

	function jgDetachVideo(jti) {
		var card = $('.jg_person[jti="' + jgSafeId(jti) + '"]');
		card.find('video.jg_person_feed').removeClass('on').each(function () { this.srcObject = null; });
	}

	function jgRestoreMedia(handle, room) {
		var call = jgCall(handle, room);
		if (!call) { return; }
		$('#jg_detail .jg_person').each(function () {
			var card = $(this);
			var jti = card.attr('jti') || '';
			if (call.video[jti]) {
				card.find('.jg_person_video_toggle').addClass('on').text(jgT('Watching'));
			}
			if (call.captions[jti] && !call.captions[jti].waiting) {
				card.find('.jg_person_caption_toggle').addClass('on').text(jgT('Translated'));
			}
			var lines = call.lines[jti] || [];
			var box = card.find('.jg_person_captions').empty();
			lines.forEach(function (line) { $('<div>').text(line).appendTo(box); });
			if (call.remote[jti]) {
				var video = card.find('video.jg_person_feed').first();
				if (video.length) {
					video[0].srcObject = call.remote[jti];
					video.addClass('on');
				}
			}
			if (call.captions[jti] && call.captions[jti].waiting && call.remote[jti]) {
				jgCaptionStart(handle, room, jti);
			}
		});
	}

	function jgRenegotiate(handle, room, jti, pc) {
		pc.createOffer().then(function (offer) {
			return pc.setLocalDescription(offer);
		}).then(function () {
			jgSend(handle, room, { type: 'offer', sdp: pc.localDescription.sdp, to: jti });
		}).catch(function () {});
	}

	function jgVideoToggle(handle, room, jti, button) {
		var call = jgCall(handle, room);
		if (!call || !jti) { return; }
		var want = !call.video[jti];
		call.video[jti] = want;
		jgSend(handle, room, { type: 'video', want: want ? 'on' : 'off', to: jti });
		$(button).toggleClass('on', want).text(want ? jgT('Watching') : jgT('Video'));
		if (!want) { jgDetachVideo(jti); }
	}

	function jgVideoPublish(handle, room, jti, kind) {
		var call = jgCall(handle, room);
		if (!call || !jti) { return; }
		kind = kind || call.share || 'camera';
		if (call.published[jti] === kind && call.pcs[jti]) { return; }
		call.publish[jti] = kind;
		jgSourceStream(call, kind).then(function (stream) {
			if (!stream || jgCalls[jgKey(handle, room)] !== call || !call.publish[jti]) { return; }
			var pc = jgPeer(handle, room, jti);
			if (!pc) { return; }
			pc.getSenders().forEach(function (sender) {
				if (sender.track && sender.track.kind === 'video') {
					try { pc.removeTrack(sender); } catch (e) {}
				}
			});
			var track = stream.getVideoTracks()[0];
			if (!track) { return; }
			pc.addTrack(track, stream);
			call.published[jti] = kind;
			jgRenegotiate(handle, room, jti, pc);
		});
	}

	// Where a picture comes from. Camera and screen are the device's; music and
	// marker are canvases already on this page; studio is the app's own window
	// (or a source it registers on window.jawnosMediaSources).
	function jgSourceKinds() {
		var kinds = [['camera', jgT('Camera')], ['studio', jgT('Studio')], ['music', jgT('#video')], ['marker', jgT('Marker')]];
		if (navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia) {
			kinds.splice(1, 0, ['screen', jgT('Screen')]);
		}
		return kinds;
	}

	function jgCanvasById(id) {
		var el = document.getElementById(id);
		if (!el) { return null; }
		if (el.tagName && el.tagName.toLowerCase() === 'canvas' && el.captureStream) { return el; }
		return null;
	}

	function jgMusicCanvas() {
		var player = document.getElementById('video');
		var miss = player ? (player.getAttribute('miss') || '') : '';
		return (miss && jgCanvasById(miss + '_visualizer')) || jgCanvasById('video') || null;
	}

	function jgSourceStream(call, kind) {
		if (call.sources[kind]) { return Promise.resolve(call.sources[kind]); }
		if (call.sourcePromises[kind]) { return call.sourcePromises[kind]; }

		var promise;

		if (kind === 'camera') {
			promise = (navigator.mediaDevices && navigator.mediaDevices.getUserMedia)
				? navigator.mediaDevices.getUserMedia({ video: true })
				: Promise.reject();
		} else if (kind === 'screen' || kind === 'studio') {
			var registered = (window.jawnosMediaSources || {})[kind];
			if (typeof registered === 'function') {
				promise = Promise.resolve(registered());
			} else if (navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia) {
				promise = navigator.mediaDevices.getDisplayMedia({ video: true });
			} else {
				promise = Promise.reject();
			}
		} else if (kind === 'music') {
			promise = Promise.resolve(jgMusicCanvas() ? jgMusicCanvas().captureStream(30) : null);
		} else if (kind === 'marker') {
			promise = Promise.resolve(jgCanvasById('whiteboard') ? jgCanvasById('whiteboard').captureStream(30) : null);
		} else {
			promise = Promise.reject();
		}

		call.sourcePromises[kind] = promise.then(function (stream) {
			if (!stream) { return null; }
			call.sources[kind] = stream;
			return stream;
		}).catch(function () { return null; });

		return call.sourcePromises[kind];
	}

	// Video is a pull: the source is stopped the moment nobody asks for it.
	function jgSourceRelease(call, kind) {
		if (!kind) { return; }
		var wanted = Object.keys(call.publish).some(function (jti) { return call.publish[jti] === kind; });
		if (wanted) { return; }
		var stream = call.sources[kind];
		if (stream) {
			stream.getTracks().forEach(function (track) { try { track.stop(); } catch (e) {} });
		}
		delete call.sources[kind];
		delete call.sourcePromises[kind];
	}

	function jgVideoUnpublish(handle, room, jti) {
		var call = jgCall(handle, room);
		if (!call) { return; }
		var kind = call.publish[jti];
		delete call.publish[jti];
		delete call.published[jti];
		var pc = call.pcs[jti];
		if (pc) {
			pc.getSenders().forEach(function (sender) {
				if (sender.track && sender.track.kind === 'video') {
					try { pc.removeTrack(sender); } catch (e) {}
				}
			});
			jgRenegotiate(handle, room, jti, pc);
		}
		jgSourceRelease(call, kind);
		if (!Object.keys(call.publish).length && call.camera) {
			call.camera.getTracks().forEach(function (track) { try { track.stop(); } catch (e) {} });
			call.camera = null;
			call.cameraPromise = null;
		}
	}

	function jgCaptionToggle(handle, room, jti, button) {
		var call = jgCall(handle, room);
		if (!call || !jti) { return; }
		var state = call.captions[jti];
		if (state && !state.waiting) {
			state.active = false;
			try { if (state.rec && state.rec.state === 'recording') { state.rec.stop(); } } catch (e) {}
			try { if (state.ctx && state.ctx.close) { state.ctx.close(); } } catch (e) {}
			delete call.captions[jti];
			$(button).removeClass('on').text(jgT('Translate'));
			return;
		}
		$(button).addClass('on').text(jgT('Translating'));
		jgCaptionStart(handle, room, jti);
	}

	function jgCaptionStart(handle, room, jti) {
		var call = jgCall(handle, room);
		if (!call) { return; }
		if (call.captions[jti] && !call.captions[jti].waiting) { return; }
		var stream = call.remote[jti];
		if (!stream) { call.captions[jti] = { waiting: true }; return; }

		var ctx = null;
		var analyser = null;
		var buf = null;

		try {
			ctx = new (window.AudioContext || window.webkitAudioContext)();
			analyser = ctx.createAnalyser();
			analyser.fftSize = 1024;
			ctx.createMediaStreamSource(stream).connect(analyser);
			buf = new Float32Array(analyser.fftSize);
		} catch (e) {
			ctx = null;
		}

		var state = { waiting: false, active: true, ctx: ctx, analyser: analyser, buf: buf, stream: stream, busy: false };
		call.captions[jti] = state;
		jgCaptionCycle(handle, room, jti, state);
	}

	function jgCaptionCycle(handle, room, jti, state) {
		if (!state.active) { return; }
		var rec = null;
		try { rec = new MediaRecorder(state.stream); } catch (e) { rec = null; }
		if (!rec) { state.active = false; return; }

		var chunks = [];
		var loud = false;
		var started = Date.now();
		state.rec = rec;
		rec.ondataavailable = function (e) { if (e.data && e.data.size) { chunks.push(e.data); } };

		var sample = function () {
			if (!state.active || !state.analyser) { return; }
			state.analyser.getFloatTimeDomainData(state.buf);
			var sum = 0;
			for (var i = 0; i < state.buf.length; i++) { sum += state.buf[i] * state.buf[i]; }
			if (Math.sqrt(sum / state.buf.length) > 0.012) { loud = true; }
			if (Date.now() - started < 3800) { setTimeout(sample, 100); }
		};

		rec.onstop = function () {
			if (!state.active) { return; }
			state.rec = null;
			if (loud && !state.busy) {
				var blob = new Blob(chunks, { type: rec.mimeType || 'audio/webm' });
				if (blob.size > 1200) { jgCaptionSend(handle, room, jti, state, blob); }
			}
			setTimeout(function () { jgCaptionCycle(handle, room, jti, state); }, 250);
		};

		rec.start();
		sample();
		setTimeout(function () {
			if (state.active && rec.state === 'recording') { try { rec.stop(); } catch (e) {} }
		}, 4000);
	}

	function jgCaptionSend(handle, room, jti, state, blob) {
		state.busy = true;
		$.ajax({
			url: '/manager/dictate?lang=auto',
			type: 'POST',
			data: blob,
			processData: false,
			contentType: blob.type || 'audio/webm'
		}).done(function (r) {
			var text = r && r.text;
			if (!text) { state.busy = false; return; }
			jgCaptionLine(handle, room, jti, text);
			$.ajax({
				url: '/manager/junderground/translate',
				type: 'POST',
				data: { incoming_data: JSON.stringify({ text: text }) }
			}).done(function (t) {
				if (t && t.ok && t.text && t.text !== text) { jgCaptionLine(handle, room, jti, t.text); }
			}).always(function () { state.busy = false; });
		}).fail(function () { state.busy = false; });
	}

	function jgCaptionLine(handle, room, jti, text) {
		var call = jgCall(handle, room);
		if (!call) { return; }
		var lines = call.lines[jti] = call.lines[jti] || [];
		lines.push(String(text));
		while (lines.length > 3) { lines.shift(); }
		var box = $('.jg_person[jti="' + jgSafeId(jti) + '"] .jg_person_captions').empty();
		lines.forEach(function (line) { $('<div>').text(line).appendTo(box); });
	}

	function jgFriend(handle, subject, button) {
		$.ajax({
			url: '/manager/junderground/friend',
			type: 'POST',
			data: { incoming_data: JSON.stringify({ handle: subject }) }
		}).done(function (r) {
			if (r && r.ok) {
				jgFriends[subject] = 1;
				$(button).addClass('on').text(jgT('Friend'));
			}
		});
	}

	function jgVisitsSync(handle, room, roster, joined) {
		var self = jgSelfFor(handle, room);
		var present = {};
		(roster || []).forEach(function (entry) {
			if (entry.subject && entry.subject !== self) { present[entry.subject] = 1; }
		});
		var here = jgKey(handle, room);
		Object.keys(jgVisits).forEach(function (who) {
			if (!joined || !present[who] || jgVisits[who].room !== here) { jgVisitStop(who); }
		});
		if (!joined) { return; }
		Object.keys(present).forEach(function (who) {
			if (!jgVisits[who] || jgVisits[who].room !== here) { jgVisitStart(who, here); }
		});
	}

	function jgVisitStart(who, room_key) {
		if (jgVisits[who]) { return; }
		jgVisits[who] = { room: room_key, uuid: '' };
		$.ajax({
			url: '/manager/appointment/writer',
			type: 'POST',
			dataType: 'json',
			data: { app: who, type: 'start', source: 'Chat', timestamp: Date.now() }
		}).done(function (r) {
			if (jgVisits[who] && r && r.uuid) { jgVisits[who].uuid = r.uuid; }
		});
	}

	function jgVisitStop(who) {
		var visit = jgVisits[who];
		if (!visit) { return; }
		delete jgVisits[who];
		$.ajax({
			url: '/manager/appointment/writer',
			type: 'POST',
			dataType: 'json',
			data: { app: who, type: 'stop', source: 'Chat', uuid: visit.uuid || '', timestamp: Date.now() }
		});
	}

	function jgVisitsStopAll() {
		Object.keys(jgVisits).forEach(jgVisitStop);
	}


	// ---- broadcast -----------------------------------------------------
	// The room's citizen (the renter) may send many streams at once. Each one is
	// a separate track on every listener's connection, announced by id so the
	// listener can name them; the microphone is still its own track. Nothing is
	// captured until the citizen presses Broadcast.

	function jgBroadcastSources() {
		var list = [
			{ id: 'camera', label: jgT('Camera'), kind: 'video', get: function () {
				return navigator.mediaDevices.getUserMedia({ video: true });
			} },
			{ id: 'marker', label: jgT('Marker'), kind: 'video', get: function () {
				var canvas = jgCanvasById('whiteboard');
				return Promise.resolve(canvas ? canvas.captureStream(30) : null);
			} },
			{ id: 'music', label: jgT('#video'), kind: 'video', get: function () {
				var canvas = jgMusicCanvas();
				return Promise.resolve(canvas ? canvas.captureStream(30) : null);
			} }
		];

		if (navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia) {
			list.splice(1, 0, { id: 'screen', label: jgT('Screen'), kind: 'video', get: function () {
				return navigator.mediaDevices.getDisplayMedia({ video: true });
			} });
		}

		var studio = window.jawnosMediaSources || {};

		if (typeof studio.studio === 'function') {
			list.push({ id: 'studio', label: jgT('Studio master'), kind: 'audio', get: function () {
				return Promise.resolve(studio.studio());
			} });
		}

		if (typeof studio.studioChannels === 'function') {
			studio.studioChannels().forEach(function (channel) {
				list.push({ id: channel.id, label: channel.label, kind: channel.kind || 'audio', get: function () {
					return Promise.resolve(channel.stream);
				} });
			});
		}

		return list;
	}

	function jgRenderBroadcast(handle, room) {
		var box = $('#jg_broadcast').empty();
		var call = jgCall(handle, room);
		if (!call || call.role !== 'citizen') { return; }

		$('<div class="jg_scope">').text(jgT('Broadcast for the room')).appendTo(box);

		jgBroadcastSources().forEach(function (source) {
			var row = $('<label class="jg_broadcast_row">').appendTo(box);
			var tick = $('<input type="checkbox">').attr({ 'data-source': source.id }).appendTo(row);
			if (call.broadcastStreams[source.id]) { tick.prop('checked', true); }
			$('<span>').text(source.label + ' · ' + jgT(source.kind)).appendTo(row);
		});

		$('<button type="button" id="jg_broadcast_go" class="jg_person_btn">')
			.attr({ handle: handle, room: room })
			.text(call.broadcastOn ? jgT('Stop broadcast') : jgT('Broadcast'))
			.appendTo(box);
	}

	function jgBroadcastTo(handle, room, jti) {
		var call = jgCall(handle, room);
		if (!call || !call.broadcastOn || !jti) { return; }
		var pc = jgPeer(handle, room, jti);
		if (!pc) { return; }

		var added = false;
		Object.keys(call.broadcastStreams).forEach(function (id) {
			var stream = call.broadcastStreams[id];
			stream.getTracks().forEach(function (track) {
				var there = pc.getSenders().some(function (sender) { return sender.track === track; });
				if (there) { return; }
				pc.addTrack(track, stream);
				added = true;
			});
		});

		if (added) { jgRenegotiate(handle, room, jti, pc); }
	}

	function jgBroadcastStop(handle, room, announce) {
		var call = jgCall(handle, room);
		if (!call) { return; }
		call.broadcastOn = false;

		Object.keys(call.pcs).forEach(function (jti) {
			var pc = call.pcs[jti];
			if (!pc) { return; }
			pc.getSenders().forEach(function (sender) {
				if (sender.track && call.broadcastTracks[sender.track.id]) {
					try { pc.removeTrack(sender); } catch (e) {}
				}
			});
			jgRenegotiate(handle, room, jti, pc);
		});

		Object.keys(call.broadcastStreams).forEach(function (id) {
			call.broadcastStreams[id].getTracks().forEach(function (track) { try { track.stop(); } catch (e) {} });
		});

		call.broadcastStreams = {};
		call.broadcastTracks = {};
		if (announce !== false) {
			jgSend(handle, room, { type: 'broadcast', on: 'no', streams: [] });
		}
		jgRenderBroadcast(handle, room);
	}

	function jgBroadcastToggle(handle, room) {
		var call = jgCall(handle, room);
		if (!call) { return; }
		if (call.broadcastOn) { jgBroadcastStop(handle, room, true); return; }

		var chosen = [];
		$('#jg_broadcast input[data-source]:checked').each(function () {
			chosen.push($(this).attr('data-source'));
		});
		if (!chosen.length) {
			$('#jg_status').text(jgT('Choose something to broadcast.'));
			return;
		}

		var sources = jgBroadcastSources().filter(function (source) {
			return chosen.indexOf(source.id) >= 0;
		});

		Promise.all(sources.map(function (source) {
			return Promise.resolve(source.get()).then(function (stream) {
				return stream ? { source: source, stream: stream } : null;
			}).catch(function () { return null; });
		})).then(function (got) {
			if (jgCalls[jgKey(handle, room)] !== call) { return; }
			var live = got.filter(function (item) { return item; });
			if (!live.length) {
				$('#jg_status').text(jgT('Nothing could be captured.'));
				return;
			}

			call.broadcastStreams = {};
			call.broadcastTracks = {};
			live.forEach(function (item) {
				call.broadcastStreams[item.source.id] = item.stream;
				item.stream.getTracks().forEach(function (track) { call.broadcastTracks[track.id] = 1; });
			});
			call.broadcastOn = true;

			jgSend(handle, room, {
				type: 'broadcast',
				on: 'yes',
				streams: live.map(function (item) {
					return { id: item.stream.id, label: item.source.label, kind: item.source.kind };
				})
			});

			Object.keys(call.pcs).forEach(function (jti) { jgBroadcastTo(handle, room, jti); });
			jgRenderBroadcast(handle, room);
			$('#jg_status').text(jgT('Broadcasting'));
		});
	}

	function jgBroadcastSeen(handle, room, msg) {
		var call = jgCall(handle, room);
		if (!call) { return; }
		call.remoteBroadcast = call.remoteBroadcast || {};
		call.remoteBroadcast[msg.from_jti] = (msg.on === 'no') ? [] : (msg.streams || []);
		jgRenderBroadcasts(handle, room);
	}

	function jgRenderBroadcasts(handle, room) {
		var call = jgCall(handle, room);
		if (!call) { return; }

		$('#jg_detail .jg_person').each(function () {
			var card = $(this);
			var jti = card.attr('jti') || '';
			var streams = (call.remoteBroadcast && call.remoteBroadcast[jti]) || [];
			var box = card.find('.jg_person_streams');

			if (!streams.length) {
				if (box.children().length) { box.empty(); box.removeAttr('count'); }
				return;
			}

			var signature = streams.map(function (s) { return s.id; }).join(',');
			if (box.attr('count') != signature) {
				box.empty();
				box.attr('count', signature);
				streams.forEach(function (stream) {
					var row = $('<div class="jg_person_stream">').appendTo(box);
					var el = (stream.kind === 'video')
						? $('<video class="jg_person_feed on" playsinline autoplay>')
						: $('<audio autoplay>');
					el.attr('data-stream', stream.id).appendTo(row);
					$('<div class="jg_scope">').text(stream.label || '').appendTo(row);
				});
			}

			box.find('[data-stream]').each(function () {
				var id = $(this).attr('data-stream');
				var stream = call.remotes[id];
				if (stream && this.srcObject !== stream) {
					this.srcObject = stream;
					var playing = this.play();
					if (playing && playing.catch) { playing.catch(function () {}); }
				}
			});
		});
	}

	function jgPost(path, payload, done) {
		$.ajax({
			url: path, type: 'POST', dataType: 'json',
			data: { incoming_data: JSON.stringify(payload || {}) }
			}).done(done).fail(function () {
				$('#jg_status').text(jgT('Could not reach the switch.'));
				$('#jg_canonical').text('');
			});
	}

	function jgDial() {
		$('#jg_status').text(jgT('Dialling…'));
		$('#jg_canonical').text('');
		jgPost('/manager/junderground/dial', { picks: jgPicks() }, function (r) {
			$('#jg_status').text(r.error || '');
			jgNames = r.error ? {} : jgNamesFrom(r);
			var canonical = r.error ? '' : jgScope(r.dial, jgNames);
			$('#jg_canonical').text(canonical);
			var unknown = (r.unknown && Object.keys(r.unknown).length) ? jgScope(r.unknown, {}) : '';
			$('#jg_unknown').text(unknown ? jgT('Not in the switch lexicon yet') + ': ' + unknown : '');
			var box = $('#jg_rooms').empty();
			var rooms = r.rooms || [];
			if (!rooms.length) {
				$('<div class="jg_empty">').text(jgT('No room on that dial.')).appendTo(box);
				return;
			}
			rooms.forEach(function (room) {
				var card = $('<div class="jg_room">').attr({ handle: room.handle, room: room.room });
				$('<div class="jg_room_name">').text(room.name || room.room).appendTo(card);
				$('<div class="jg_scope">').text(jgScope(room.constructs, jgNames)).appendTo(card);
				if (room.advertised) { $('<span class="jg_badge">').text(jgT('Advertised')).appendTo(card); }
				box.append(card);
			});
		});
	}

	function jgOpen(handle, room) {
		jgPost('/manager/junderground/room', { handle: handle, room: room }, function (data) {
			jgRenderDetail(handle, room, data);
		});
	}

	function jgRenderDetail(handle, room, data) {
		var box = $('#jg_detail').empty();
		var meta = data.room || {};
		var door = data.door || {};
		var grade = data.grade || {};
		var rentals = (data.rentals && data.rentals.rentals) || [];
		var roster = (data.presence && data.presence.roster) || [];
		var key = handle + '/' + room;

		$('<div class="jg_detail_head">')
			.append($('<b>').text(meta.name || room))
			.append($('<span class="jg_scope">').text(key))
			.appendTo(box);

		$('<div class="jg_scope">').text(jgScope(meta.constructs, jgNames)).appendTo(box);

		var doorBox = $('<div class="jg_door">').attr('data-state', door.state || 'open')
			.text(jgT('Door') + ': ' + jgT(door.state || 'open')).appendTo(box);
		if (door.notify_at) {
			$('<div class="jg_scope">').text(jgT('Reserved') + ' ' + jgTime(door.start) +
				' · ' + jgT('notice') + ' ' + jgTime(door.notify_at)).appendTo(doorBox);
		}

		if (rentals.length) {
			var rentalBox = $('<div class="jg_rentals">').appendTo(box);
			$('<div class="jg_scope">').text(jgT('Rentals')).appendTo(rentalBox);
			rentals.forEach(function (rental) {
				$('<div class="jg_rental">').text(
					(rental.label || rental.event || jgT('Reserved')) + ' · ' +
					jgTime(rental.start) + '–' + jgTime(rental.end) +
					(rental.guest_start ? ' · ' + jgT('guests') + ' ' + jgTime(rental.guest_start) + '–' + jgTime(rental.guest_end) : '')
				).appendTo(rentalBox);
			});
		}

		var gradeBox = $('<div class="jg_row">').appendTo(box);
		$('<span class="jg_grade">').attr('data-grade', grade.grade || 'empty')
			.text(jgT(grade.grade || 'empty')).appendTo(gradeBox);
		if (grade.block) { $('<span class="jg_block">').text(jgT('An enemy is in this room')).appendTo(gradeBox); }

		var self = jgSelfFor(handle, room);
		var others = roster.filter(function (entry) { return entry.subject && entry.subject !== self; });
		if (others.length) {
			var rosterBox = $('<div class="jg_roster">').appendTo(box);
			others.forEach(function (entry) {
				jgPersonCard(entry, handle, room).appendTo(rosterBox);
			});
		}

		jgRenderMedia(handle, room);
		jgRestoreMedia(handle, room);
		jgRenderBroadcast(handle, room);
		jgRenderBroadcasts(handle, room);
		jgVisitsSync(handle, room, roster, !!jgPresence[jgKey(handle, room)]);

		var actions = $('<div class="jg_row">').appendTo(box);
		$('<button type="button" id="jg_join">').attr({ handle: handle, room: room })
			.text(jgT('Join')).appendTo(actions);
		if (jgPresence[key]) {
			$('<button type="button" id="jg_leave">').attr({ handle: handle, room: room })
				.text(jgT('Leave')).appendTo(actions);
		}
	}

	$(document).on('click', '#jg_save', function () {
		jgPost('/manager/junderground/config', {
			url: $('#jg_url').val(), handle: $('#jg_handle').val(),
			known: $('#jg_known').val(), blacklist: $('#jg_blacklist').val()
		}, function (r) {
			$('#jg_status').text(r.ok ? jgT('Saved') : (r.error || ''));
		});
	});

	$(document).on('click', '#jg_register', function () {
		$('#jg_status').text(jgT('Registering…'));
		jgPost('/manager/junderground/register', {}, function (r) {
			if (r.error) { $('#jg_status').text(r.error); return; }
			var status = (r.admission && r.admission.status) || r.status || 'pending';
			$('#jg_status').text(jgT('Registered') + ' · ' + status);
		});
	});

	$(document).on('click', '#jg_dial', jgDial);

	$(document).on('click', '#jg_panel .jg_room', function () {
		jgOpen($(this).attr('handle'), $(this).attr('room'));
	});

	$(document).on('click', '#jg_join', function () {
		var handle = $(this).attr('handle');
		var room = $(this).attr('room');
		var ticket = $.trim($('#jg_ticket').val());
		$('#jg_status').text(jgT('Joining…'));
		jgPost('/manager/junderground/join', { handle: handle, room: room, ticket: ticket }, function (r) {
			if (r.error) { $('#jg_status').text(r.error); return; }
			var call = jgCall(handle, room);
			if (call && r.role) { call.role = r.role; }
			jgPresence[handle + '/' + room] = r.presence_id;
			$('#jg_status').text((r.role || 'guest') + (r.ticketed ? ' · ' + jgT('pass') : ''));
			jgSocketOpen(handle, room, r.grant);
			jgOpen(handle, room);
		});
	});

	$(document).on('click', '.jg_person_video_toggle', function () {
		jgVideoToggle($(this).attr('handle'), $(this).attr('room'), $(this).attr('jti'), this);
	});

	$(document).on('click', '.jg_person_caption_toggle', function () {
		jgCaptionToggle($(this).attr('handle'), $(this).attr('room'), $(this).attr('jti'), this);
	});

	$(document).on('click', '.jg_person_friend', function () {
		jgFriend($(this).attr('handle'), $(this).attr('handle'), this);
	});

	$(document).on('change', '#jg_share_source', function () {
		var handle = $(this).attr('handle');
		var room = $(this).attr('room');
		var call = jgCall(handle, room);
		if (!call) { return; }
		call.share = $(this).val() || 'camera';
		Object.keys(call.publish).forEach(function (jti) {
			jgVideoPublish(handle, room, jti, call.share);
		});
		Object.keys(call.sources).forEach(function (kind) {
			if (kind !== call.share) { jgSourceRelease(call, kind); }
		});
	});

	$(document).on('click', '#jg_broadcast_go', function () {
		jgBroadcastToggle($(this).attr('handle'), $(this).attr('room'));
	});

	$(document).on('click', '#jg_mute', function () {
		var handle = $(this).attr('handle');
		var room = $(this).attr('room');
		var call = jgCall(handle, room);
		if (!call || !call.stream) { return; }
		call.muted = !call.muted;
		call.stream.getAudioTracks().forEach(function (track) { track.enabled = !call.muted; });
		jgRenderMedia(handle, room);
	});

	$(document).on('click', '#jg_leave', function () {
		var handle = $(this).attr('handle');
		var room = $(this).attr('room');
		var key = handle + '/' + room;
		jgPost('/manager/junderground/leave', {
			handle: handle, room: room, presence_id: jgPresence[key] || ''
		}, function (r) {
			delete jgPresence[key];
			jgVisitsStopAll();
			jgSocketClose(handle, room);
			$('#jg_status').text(r.error || jgT('Left the room'));
			jgOpen(handle, room);
		});
	});

	$(document).on('click', '.mail_subsection', function () {
		setTimeout(function () { jgConfigWhenReady(10); }, 100);
	});

	if ($('#jg_panel').length) { jgConfigLoad(); }
})();
