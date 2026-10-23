// The remote-audio tap. The main thread connects this node to the shared music
// graph's limiter (and a zero-gain sink, so the graph pulls it without making a
// second sound). It does not render audio itself: it collects the input into
// 20 ms frames of signed 16-bit stereo and hands each frame to the main thread,
// which sends it down the websocket. ~192 KB/s at 48 kHz.
//
// `active` is set by the main thread when a stream is running; a paused player
// sends false and no frames are produced, so the remote's pacat drains rather
// than receiving silence. `reset` throws away a partial frame after a seek.
class MusicStreamTap extends AudioWorkletProcessor {
	constructor() {
		super();
		this.active = false;
		this.frames = Math.max(128, Math.round(sampleRate * 0.02));
		this.chunk = new Int16Array(this.frames * 2);
		this.count = 0;
		this.port.onmessage = (e) => {
			const d = e.data || {};
			if (d.active !== undefined) { this.active = !!d.active; }
			if (d.reset) { this.count = 0; }
		};
	}
	process(inputs) {
		if (!this.active) { return true; }
		const input = inputs[0];
		if (!input || !input.length || !input[0]) { return true; }
		const channels = input.length;
		const n = input[0].length;
		for (let i = 0; i < n; i++) {
			let l = input[0][i];
			let r = channels > 1 ? input[1][i] : l;
			l = l < -1 ? -1 : (l > 1 ? 1 : l);
			r = r < -1 ? -1 : (r > 1 ? 1 : r);
			this.chunk[this.count * 2] = (l * 32767) | 0;
			this.chunk[this.count * 2 + 1] = (r * 32767) | 0;
			this.count++;
			if (this.count >= this.frames) {
				const out = this.chunk;
				// the context time rides along so the main thread can drop a backlog
				// instead of sending a one-second burst after it was busy decoding
				this.port.postMessage({ pcm: out, t: currentTime }, [out.buffer]);
				this.chunk = new Int16Array(this.frames * 2);
				this.count = 0;
			}
		}
		return true;
	}
}
registerProcessor('music-stream-tap', MusicStreamTap);
