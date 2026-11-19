// ===========================================================================
// Audio files
// ===========================================================================
// A rendered AudioBuffer becomes a file the browser can upload. The drum loop
// library writes a WAV of a saved pattern; the export renders each track the
// same way. 16-bit PCM is deliberate: every browser decodes it, and the server
// transcodes to MP3 or FLAC when a different format is asked for.

function studioBufferToWav(buffer) {
	var channels = Math.max(1, buffer.numberOfChannels || 1);
	var rate = buffer.sampleRate || 44100;
	var frames = buffer.length || 0;
	var dataBytes = frames * channels * 2;
	var view = new DataView(new ArrayBuffer(44 + dataBytes));
	var write = function (at, text) {
		for (var i = 0; i < text.length; i++) { view.setUint8(at + i, text.charCodeAt(i)); }
	};
	write(0, 'RIFF');
	view.setUint32(4, 36 + dataBytes, true);
	write(8, 'WAVE');
	write(12, 'fmt ');
	view.setUint32(16, 16, true);
	view.setUint16(20, 1, true);          // PCM
	view.setUint16(22, channels, true);
	view.setUint32(24, rate, true);
	view.setUint32(28, rate * channels * 2, true);
	view.setUint16(32, channels * 2, true);
	view.setUint16(34, 16, true);
	write(36, 'data');
	view.setUint32(40, dataBytes, true);

	var rows = [];
	for (var c = 0; c < channels; c++) { rows.push(buffer.getChannelData(c)); }
	var at = 44;
	for (var i = 0; i < frames; i++) {
		for (var c = 0; c < channels; c++) {
			var sample = rows[c][i] || 0;
			sample = Math.max(-1, Math.min(1, sample));
			view.setInt16(at, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
			at += 2;
		}
	}
	return new Blob([view], { type: 'audio/wav' });
}
