/*
 * sco_helper - take the SCO/eSCO audio of one HFP call and speak a small
 *              line protocol on stdin/stdout.
 *
 * The daemon (perl/Sco.pl) owns the policy; this program owns the audio. It
 * binds a BTPROTO_SCO socket on the local adapter, waits for the phone's
 * Hands-Free link, and from then on answers one JSON object per line:
 *
 *   in   {"cmd":"play","file":"/abs/path.raw","id":7}
 *   in   {"cmd":"tone","hz":440,"ms":400,"id":8}
 *   in   {"cmd":"record","file":"/abs/path.wav","ms":30000,
 *         "silence_ms":1200,"min_ms":400,"id":9}
 *   in   {"cmd":"stop"}
 *   in   {"cmd":"quit"}
 *   out  {"event":"listening","local":"..:.."}
 *   out  {"event":"accepted","peer":"..:.."}
 *   out  {"event":"played","id":7,"ms":420}
 *   out  {"event":"recorded","id":9,"file":"...","ms":3120,"silence":true}
 *   out  {"event":"stopped","id":9}
 *   out  {"event":"closed","reason":".."}
 *   out  {"event":"error","error":".."}
 *
 * The uplink is CVSD 8 kHz mono s16le, written 7.5 ms at a time (the eSCO
 * frame). The downlink is the same shape and is what the recorder writes; a
 * WAV header is written up front and patched when the clip closes, so a call
 * cut off by the link dropping still leaves a playable file.
 *
 * Build: see scripts/build_sco.pl.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include <alsa/asoundlib.h>
#include <bluetooth/bluetooth.h>
#include <bluetooth/hci.h>
#include <bluetooth/hci_lib.h>
#include <bluetooth/sco.h>

#define RATE 8000
#define CHUNK_SAMPLES 60                 /* 7.5 ms of 8 kHz s16le */
#define CHUNK_BYTES (CHUNK_SAMPLES * 2)
#define BYTES_PER_MS (RATE * 2 / 1000)
#define CHUNK_NS 7500000LL
/* how long the call audio must be flowing before a prompt starts */
#define SETTLE_NS 1200000000LL
/* how long a silent link is waited on before it is treated as a call anyway */
#define SETTLE_WAIT_NS 8000000000LL

static volatile sig_atomic_t running = 1;
static int sco_fd = -1, listen_fd = -1;
static const char *local_addr = NULL;
static const char *peer_want = NULL;
static int voice = BT_VOICE_CVSD_16BIT;
/* --silence-level: the room floor to assume when the room reads as nothing at
 * all. The record's own reader learns the real one (see the room reader). */
static int silence_level = 400;
static int loopback = 0, fast = 0;
static const char *pcm_dev = NULL;
static const char *pipe_in_cmd = NULL, *pipe_out_cmd = NULL;
static FILE *pipe_in = NULL, *pipe_out = NULL;
static int pipe_mode = 0;
static int pipe_open_pair(void);
static int pipe_read_chunk(unsigned char *buf, size_t cap);
static int pipe_write_chunk(const unsigned char *buf, size_t len);
static int backend_open(void);
static int backend_read(unsigned char *buf, size_t cap);
static int backend_write(const unsigned char *buf, size_t len);
static int chunk_has_signal(const unsigned char *buf, size_t len);
static char pcm_error[128] = "";
static long long last_complain = 0;        /* BlueALSA PCM, e.g. bluealsa:DEV=...,PROFILE=hfp-hf */
static snd_pcm_t *pcm_cap = NULL, *pcm_play = NULL;
static const char *downlink_path = NULL, *uplink_path = NULL;
static FILE *uplink_raw = NULL;
static int have_accepted = 0;

/* ---- BlueALSA PCM ------------------------------------------------------ */

/* A Hands-Free stack (BlueALSA) owns the link; this program is just an audio
 * client. The PCM exists only while a call is up, so opening succeeds when the
 * phone starts the call and that is what "accepted" means here. */
static int pcm_open_one(snd_pcm_t **pcm, snd_pcm_stream_t dir) {
	if (*pcm) return 0;
	snd_pcm_t *h = NULL;
	int rc = snd_pcm_open(&h, pcm_dev, dir, SND_PCM_NONBLOCK);
	if (rc < 0) { snprintf(pcm_error, sizeof(pcm_error), "%s", snd_strerror(rc)); return -1; }
	if (snd_pcm_set_params(h, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
			1, RATE, 1, 40000) < 0) {
		snd_pcm_close(h);
		return -1;
	}
	snd_pcm_prepare(h);
	*pcm = h;
	return 0;
}

static void pcm_close_pair(void) {
	if (pcm_cap) { snd_pcm_drain(pcm_cap); snd_pcm_close(pcm_cap); pcm_cap = NULL; }
	if (pcm_play) { snd_pcm_drain(pcm_play); snd_pcm_close(pcm_play); pcm_play = NULL; }
}

static int pcm_read_chunk(unsigned char *buf, size_t len) {
	if (!pcm_cap) return -1;
	snd_pcm_sframes_t got = snd_pcm_readi(pcm_cap, buf, (snd_pcm_uframes_t) (len / 2));
	if (got == -EAGAIN) return 0;
	if (got < 0) {
		if (snd_pcm_recover(pcm_cap, (int) got, 1) < 0) return -1;
		return 0;
	}
	return (int) got * 2;
}

static int pcm_write_chunk(const unsigned char *buf, size_t len) {
	if (!pcm_play) return -1;
	snd_pcm_sframes_t put = snd_pcm_writei(pcm_play, buf, (snd_pcm_uframes_t) (len / 2));
	if (put == -EAGAIN) return 0;
	if (put < 0) {
		if (snd_pcm_recover(pcm_play, (int) put, 1) < 0) return -1;
		return 0;
	}
	return (int) put * 2;
}

/* ---- uplink clip ------------------------------------------------------- */

static unsigned char *clip = NULL;
static size_t clip_len = 0, clip_pos = 0;
static int clip_id = 0;
static long clip_ms = 0;
static int clip_active = 0;
static long long next_write = 0;
static long long clip_start_at = 0;
#define LEAD_IN_NS 450000000LL
static long long now_ns(void);

/* ---- recording --------------------------------------------------------- */

static FILE *rec_file = NULL;
static char rec_path[PATH_MAX];
static long rec_bytes = 0, rec_total_ms = 0;
static long rec_want_ms = 0, rec_silence_ms = 1800, rec_min_ms = 400;
static int rec_id = 0, rec_active = 0, rec_quiet = 0;

/* ---- the room reader ----------------------------------------------------
 * A caller's name is recorded the way the keyboard's dictation records a
 * phrase: the room is read first, speech has to hold before it counts, and the
 * pause that ends the name is measured against that room and against the name's
 * own peak. A fixed level cannot do it - a Bluetooth line's own hiss sits above
 * any threshold that reads as silence, so the first noisy frame used to count
 * as the name and 1.2 s of line noise then closed a clip the caller had not
 * begun. (The keyboard's copy is public/js/manager/soft_keyboard/01_scroll_dictate.js.)
 */
#define VAD_WINDOW_MS 100                 /* one judged window of the call */
#define VAD_READ_WINDOWS 5                /* half a second to read the room */
#define VAD_ONSET_WINDOWS 3               /* speech has to hold this long */
#define VAD_ROOM_FALLBACK 655.0           /* 0.02 of the 16-bit scale */
#define VAD_ROOM_MARGIN 491.0             /* 0.015 */
#define VAD_ROOM_SCALE 0.5
#define VAD_ROOM_ONSET_SCALE 1.5
#define VAD_ROOM_PEAK_RATIO 3.5

static double rec_window[VAD_READ_WINDOWS];
static int rec_window_count = 0;
static double rec_window_sq = 0;          /* sum of squares, window so far */
static long rec_window_samples = 0;
static double rec_floor = 0;
static int rec_run = 0;                   /* loud windows in a row */
static int rec_heard = 0;                 /* the name has begun */
static long rec_speech_ms = 0;
static long rec_pause_ms = 0;
static long rec_peak = 0;

/* ---- small JSON helpers (our own emitter; nothing else writes the line) - */

static void emit(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
	fflush(stdout);
}

static const char *json_escape(const char *in, char *safe, size_t cap) {
	size_t o = 0;
	for (const char *p = in ? in : ""; *p && o + 8 < cap; p++) {
		unsigned char ch = (unsigned char) *p;
		if (ch == '"' || ch == '\\') { safe[o++] = '\\'; safe[o++] = (char) ch; }
		else if (ch == '\n') { safe[o++] = '\\'; safe[o++] = 'n'; }
		else if (ch < 0x20) o += (size_t) snprintf(safe + o, cap - o, "\\u%04x", ch);
		else safe[o++] = (char) ch;
	}
	safe[o] = 0;
	return safe;
}

static void emit_error(const char *msg) {
	char safe[PATH_MAX * 2];
	printf("{\"event\":\"error\",\"error\":\"%s\"}\n", json_escape(msg, safe, sizeof(safe)));
	fflush(stdout);
}

static int json_int(const char *line, const char *key, int fallback) {
	char pat[64];
	snprintf(pat, sizeof(pat), "\"%s\"", key);
	const char *p = strstr(line, pat);
	if (!p) return fallback;
	p += strlen(pat);
	while (*p && *p != ':') p++;
	if (*p != ':') return fallback;
	p++;
	while (*p == ' ' || *p == '\t') p++;
	if (!(*p == '-' || isdigit((unsigned char) *p))) return fallback;
	return (int) strtol(p, NULL, 10);
}

static int json_str(const char *line, const char *key, char *out, size_t cap) {
	char pat[64];
	snprintf(pat, sizeof(pat), "\"%s\"", key);
	const char *p = strstr(line, pat);
	if (!p) return 0;
	p += strlen(pat);
	while (*p && *p != ':') p++;
	if (*p != ':') return 0;
	p++;
	while (*p == ' ' || *p == '\t') p++;
	if (*p != '"') return 0;
	p++;
	size_t o = 0;
	while (*p && *p != '"' && o + 1 < cap) {
		if (*p == '\\' && p[1]) {
			p++;
			switch (*p) {
			case 'n': out[o++] = '\n'; break;
			case 't': out[o++] = '\t'; break;
			default: out[o++] = *p; break;
			}
			p++;
			continue;
		}
		out[o++] = *p++;
	}
	out[o] = 0;
	return o > 0;
}

/* ---- WAV --------------------------------------------------------------- */

static void wav_header(FILE *f, uint32_t data_len, uint32_t rate) {
	uint32_t chunk = 36 + data_len, byte_rate = rate * 2, sub = 16, rate32 = rate;
	uint16_t fmt = 1, channels = 1, bits = 16, align = 2;
	fwrite("RIFF", 1, 4, f);
	fwrite(&chunk, 4, 1, f);
	fwrite("WAVEfmt ", 1, 8, f);
	fwrite(&sub, 4, 1, f);
	fwrite(&fmt, 2, 1, f);
	fwrite(&channels, 2, 1, f);
	fwrite(&rate32, 4, 1, f);
	fwrite(&byte_rate, 4, 1, f);
	fwrite(&align, 2, 1, f);
	fwrite(&bits, 2, 1, f);
	fwrite("data", 1, 4, f);
	fwrite(&data_len, 4, 1, f);
}

/* ---- recording lifecycle ------------------------------------------------ */

static void record_close(int announce, const char *reason) {
	if (!rec_active) return;
	rec_active = 0;
	/* "no speech" is as good as silence: nobody said a name */
	rec_quiet = (strcmp(reason, "silence") == 0 || strcmp(reason, "no speech") == 0);
	if (rec_file) {
		fflush(rec_file);
		if (fseek(rec_file, 0, SEEK_SET) == 0) wav_header(rec_file, (uint32_t) rec_bytes, RATE);
		fflush(rec_file);
		fsync(fileno(rec_file));
		fclose(rec_file);
		rec_file = NULL;
	}
	if (announce) {
		char safe[PATH_MAX * 2];
		emit("{\"event\":\"recorded\",\"id\":%d,\"file\":\"%s\",\"ms\":%ld,\"silence\":%s}",
			rec_id, json_escape(rec_path, safe, sizeof(safe)), rec_total_ms,
			rec_quiet ? "true" : "false");
	}
}

static void record_start(const char *path, int want_ms, int silence_ms, int min_ms, int id) {
	if (!path || !*path) { emit_error("record needs a file"); return; }
	if (rec_active) record_close(0, "replaced");
	snprintf(rec_path, sizeof(rec_path), "%s", path);
	rec_file = fopen(rec_path, "wb");
	if (!rec_file) { emit_error("cannot open recording"); return; }
	wav_header(rec_file, 0, RATE);
	fflush(rec_file);
	rec_bytes = rec_total_ms = 0;
	rec_want_ms = want_ms > 0 ? want_ms : 0;
	rec_silence_ms = silence_ms > 0 ? silence_ms : 0;
	rec_min_ms = min_ms > 0 ? min_ms : 0;
	rec_id = id;
	rec_active = 1;
	rec_window_count = 0;
	rec_window_sq = 0;
	rec_window_samples = 0;
	rec_floor = 0;
	rec_run = 0;
	rec_heard = 0;
	rec_speech_ms = 0;
	rec_pause_ms = 0;
	rec_peak = 0;
	emit("{\"event\":\"recording\",\"id\":%d}", id);
}

/* ---- downlink ----------------------------------------------------------- */

/* The room's own level, with the onset margin wider than the pause margin so
 * the room's jitter never reads as a word. */
static double vad_threshold(int onset) {
	double floor = rec_floor > 0 ? rec_floor : (silence_level > 0 ? (double) silence_level : VAD_ROOM_FALLBACK);
	double margin = floor * VAD_ROOM_SCALE;
	if (margin < VAD_ROOM_MARGIN) margin = VAD_ROOM_MARGIN;
	if (onset) margin *= VAD_ROOM_ONSET_SCALE;
	return floor + margin;
}

/* One judged 100 ms window of the caller's voice: read the room, wait for the
 * name to hold, then end the clip on a pause measured against the room and the
 * name's own peak. */
static void record_window(double rms) {
	if (rec_window_count < VAD_READ_WINDOWS) {
		rec_window[rec_window_count++] = rms;
		if (rec_window_count == VAD_READ_WINDOWS) {
			/* the clip opens right after the prompt, so the first half second is
			 * the room; its quietest window is the floor, because the caller may
			 * already be speaking in the rest of it */
			double low = rec_window[0];
			for (int i = 1; i < VAD_READ_WINDOWS; i++) {
				if (rec_window[i] < low) low = rec_window[i];
			}
			rec_floor = low;
		}
		return;
	}
	if (!rec_heard) {
		/* one loud tick is line noise or a tap, so speech has to hold before the
		 * name is taken to have started */
		if (rms <= vad_threshold(1)) { rec_run = 0; return; }
		if (++rec_run < VAD_ONSET_WINDOWS) return;
		rec_heard = 1;
		rec_run = 0;
		rec_peak = (long) rms;
		rec_speech_ms = VAD_ONSET_WINDOWS * VAD_WINDOW_MS;
		return;
	}
	if ((long) rms > rec_peak) rec_peak = (long) rms;
	int quiet = rms <= vad_threshold(0);
	int hushed = rec_peak > (long) VAD_ROOM_FALLBACK
		&& rms * VAD_ROOM_PEAK_RATIO < (double) rec_peak;
	if (!quiet && !hushed) {
		rec_pause_ms = 0;
		rec_speech_ms += VAD_WINDOW_MS;
		return;
	}
	rec_pause_ms += VAD_WINDOW_MS;
	/* the pause ends the name only once a name has been heard, and a caller who
	 * pauses to think keeps the line for as long as the ceiling allows */
	if (rec_silence_ms && rec_pause_ms >= rec_silence_ms && rec_speech_ms >= rec_min_ms) {
		record_close(1, "silence");
	}
}

/* Write one 7.5 ms chunk of the caller's voice, and decide when the clip has
 * ended. The audio is kept from the first frame, so nothing said while the
 * room is being read is lost. */
static void downlink_chunk(const unsigned char *buf, size_t len) {
	if (len > CHUNK_BYTES) len = CHUNK_BYTES;
	if (!rec_active) return;
	fwrite(buf, 1, len, rec_file);
	rec_bytes += (long) len;
	/* time comes from the bytes, not the frame count, so a short final
	 * frame cannot make the clip disagree with its own length */
	rec_total_ms = rec_bytes / BYTES_PER_MS;
	long sum = 0;
	int n = (int) (len / 2);
	for (int i = 0; i < n; i++) {
		int16_t s = (int16_t) (buf[i * 2] | (buf[i * 2 + 1] << 8));
		long v = s;
		sum += v * v;
	}
	rec_window_sq += (double) sum;
	rec_window_samples += n;
	if (rec_want_ms && rec_total_ms >= rec_want_ms) {
		record_close(1, rec_heard ? "length" : "no speech");
		return;
	}
	if (rec_window_samples >= RATE * VAD_WINDOW_MS / 1000) {
		double rms = sqrt(rec_window_sq / rec_window_samples);
		rec_window_sq = 0;
		rec_window_samples = 0;
		record_window(rms);
	}
}

static int downlink_read(int fd) {
	unsigned char buf[2048];
	ssize_t n = read(fd, buf, sizeof(buf));
	if (n <= 0) return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? 0 : -1;
	for (ssize_t off = 0; off < n; off += CHUNK_BYTES) {
		size_t take = (size_t) (n - off) > CHUNK_BYTES ? CHUNK_BYTES : (size_t) (n - off);
		downlink_chunk(buf + off, take);
	}
	return 0;
}

/* ---- uplink ------------------------------------------------------------- */

static void clip_load_file(const char *path, int id) {
	FILE *f = fopen(path, "rb");
	if (!f) { emit_error("cannot open clip"); return; }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (n <= 0) { fclose(f); emit_error("empty clip"); return; }
	free(clip);
	clip = malloc((size_t) n);
	if (!clip) { fclose(f); emit_error("out of memory"); return; }
	clip_len = fread(clip, 1, (size_t) n, f);
	fclose(f);
	clip_pos = 0;
	clip_id = id;
	clip_ms = 0;
	clip_active = 1;
	clip_start_at = now_ns() + LEAD_IN_NS;
	next_write = clip_start_at;
}

static void clip_tone(int hz, int ms, int id) {
	if (hz < 100) hz = 100;
	if (hz > 3000) hz = 3000;
	if (ms < 20) ms = 20;
	if (ms > 10000) ms = 10000;
	size_t samples = (size_t) (RATE * ms / 1000);
	free(clip);
	clip = malloc(samples * 2);
	if (!clip) { emit_error("out of memory"); return; }
	for (size_t i = 0; i < samples; i++) {
		double t = (double) i / RATE;
		/* a third of full scale: a beep the caller cannot miss, without clipping */
		int16_t v = (int16_t) (sin(2.0 * 3.141592653589793 * hz * t) * 11000);
		clip[i * 2] = (unsigned char) (v & 0xff);
		clip[i * 2 + 1] = (unsigned char) ((v >> 8) & 0xff);
	}
	clip_len = samples * 2;
	clip_pos = 0;
	clip_id = id;
	clip_ms = 0;
	clip_active = 1;
	clip_start_at = now_ns() + LEAD_IN_NS;
	next_write = clip_start_at;
}

/* One 7.5 ms of the clip toward the caller. Returns 1 when it finished now. */
static int uplink_step(int fd) {
	if (!clip_active) return 0;
	size_t take = clip_len - clip_pos;
	if (take > CHUNK_BYTES) take = CHUNK_BYTES;
	if (take) {
		unsigned char silence[CHUNK_BYTES];
		memset(silence, 0, sizeof(silence));
		if (loopback) {
			/* a file is the caller here: the fd is opened read-only, so the
			 * only sink is the uplink capture the test asked for */
			if (uplink_raw) {
				fwrite(clip + clip_pos, 1, take, uplink_raw);
				fflush(uplink_raw);
			}
			clip_pos += take;
			clip_ms += 7;
		}
		else {
			ssize_t w;
			if (pcm_dev || pipe_mode) {
				int wrote = backend_write(clip + clip_pos, take);
				if (wrote <= 0) return 0;
				w = wrote;
			}
			else {
				w = write(fd, clip + clip_pos, take);
			}
			if (w < 0) {
				if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
				emit_error("uplink write failed");
				clip_active = 0;
				return 0;
			}
			/* keep the frame shape even when the clip is not a multiple of it */
			if ((size_t) w < CHUNK_BYTES) {
				size_t pad = CHUNK_BYTES - (size_t) w;
				if (pad > sizeof(silence)) pad = sizeof(silence);
				write(fd, silence, pad);
			}
			if (uplink_raw) {
				fwrite(clip + clip_pos, 1, (size_t) w, uplink_raw);
				fflush(uplink_raw);
			}
			clip_pos += (size_t) w;
			clip_ms += 7;
		}
	}
	if (clip_pos >= clip_len) {
		clip_active = 0;
		emit("{\"event\":\"played\",\"id\":%d,\"ms\":%ld}", clip_id, clip_ms);
		return 1;
	}
	return 0;
}

/* ---- command input ------------------------------------------------------ */

static void command(const char *line) {
	char cmd[32] = "", file[PATH_MAX] = "";
	json_str(line, "cmd", cmd, sizeof(cmd));
	int id = json_int(line, "id", 0);
	if (!strcmp(cmd, "play")) {
		if (!json_str(line, "file", file, sizeof(file))) { emit_error("play needs a file"); return; }
		clip_load_file(file, id);
	} else if (!strcmp(cmd, "tone")) {
		clip_tone(json_int(line, "hz", 440), json_int(line, "ms", 400), id);
	} else if (!strcmp(cmd, "record")) {
		if (!json_str(line, "file", file, sizeof(file))) { emit_error("record needs a file"); return; }
		record_start(file, json_int(line, "ms", 30000), json_int(line, "silence_ms", 1200),
			json_int(line, "min_ms", 400), id);
	} else if (!strcmp(cmd, "stop")) {
		int was_rec = rec_active;
		if (clip_active) { clip_active = 0; emit("{\"event\":\"stopped\",\"id\":%d}", clip_id); }
		if (rec_active) { record_close(1, "stopped"); }
		else if (!was_rec) emit("{\"event\":\"stopped\",\"id\":0}");
	} else if (!strcmp(cmd, "quit")) {
		running = 0;
	} else if (!strcmp(cmd, "ping")) {
		emit("{\"event\":\"pong\"}");
	} else {
		emit_error("unknown command");
	}
}

/* ---- signals ------------------------------------------------------------ */

static void on_signal(int sig) {
	(void) sig;
	running = 0;
}

/* ---- main --------------------------------------------------------------- */

static long long now_ns(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long) ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static const char *peers_name(struct sockaddr_sco *peer) {
	static char ba[18] = "?";
	ba2str(&peer->sco_bdaddr, ba);
	return ba;
}

/* Bind a SCO listener. '' (NULL) means any adapter, which the kernel refuses
 * with EADDRINUSE as soon as one controller already has an SCO listener, so
 * the caller falls back to asking each adapter for its own address. */
static int sco_listen(const char *addr_str, char *bound, size_t bound_cap) {
	int s = socket(AF_BLUETOOTH, SOCK_SEQPACKET, BTPROTO_SCO);
	if (s < 0) return -1;
	setsockopt(s, SOL_BLUETOOTH, BT_VOICE, &voice, sizeof(voice));
	struct sockaddr_sco addr;
	memset(&addr, 0, sizeof(addr));
	addr.sco_family = AF_BLUETOOTH;
	if (addr_str && str2ba(addr_str, &addr.sco_bdaddr) < 0) {
		close(s);
		errno = EINVAL;
		return -1;
	}
	if (bind(s, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
		int saved = errno;
		close(s);
		errno = saved;
		return -1;
	}
	if (listen(s, 1) < 0) {
		int saved = errno;
		close(s);
		errno = saved;
		return -1;
	}
	if (bound && bound_cap) {
		if (addr_str) snprintf(bound, bound_cap, "%s", addr_str);
		else snprintf(bound, bound_cap, "any");
	}
	return s;
}

/* Every adapter the kernel knows. hci_dev_list() left BlueZ's public API, so
 * the ids are probed directly; /sys/class/bluetooth is missing on some
 * kernels, which is why this is not a directory walk. */
static int addrs_from_sys(char addresses[][18], int max) {
	/* the default route first: the adapter the house paired the phone with */
	int order[16];
	int out = 0;
	int first = hci_get_route(NULL);
	int count = 0;
	if (first >= 0) order[count++] = first;
	for (int id = 0; id < 16; id++) {
		if (id == first) continue;
		order[count++] = id;
	}
	for (int i = 0; i < count && out < max; i++) {
		int dd = hci_open_dev(order[i]);
		if (dd < 0) continue;
		bdaddr_t ba;
		int ok = hci_devba(order[i], &ba) == 0;
		hci_close_dev(dd);
		if (!ok) continue;
		char line[18];
		ba2str(&ba, line);
		if (strlen(line) == 17) snprintf(addresses[out++], 18, "%s", line);
	}
	return out;
}

static int backend_open(void) {
	return pipe_mode ? pipe_open_pair() : -1;
}

/* A frame that is all zeros is not a call: our own sink keeps producing frames
 * whether or not the phone's audio path is up, and a link still settling hands
 * us digital silence. */
static int chunk_has_signal(const unsigned char *buf, size_t len) {
	for (size_t i = 0; i + 1 < len; i += 2) {
		if (buf[i] || buf[i + 1]) return 1;
	}
	return 0;
}

static int backend_read(unsigned char *buf, size_t cap) {
	return pipe_mode ? pipe_read_chunk(buf, cap) : pcm_read_chunk(buf, cap);
}

static int backend_write(const unsigned char *buf, size_t len) {
	return pipe_mode ? pipe_write_chunk(buf, len) : pcm_write_chunk(buf, len);
}

/* A PipeWire backend: the caller's audio arrives on a capture command's
 * stdout, and what we write goes to a playback command's stdin. The phones do
 * the audio routing; this program only speaks the plan. */
static int pipe_open_pair(void) {
	if (!pipe_in && pipe_in_cmd) {
		pipe_in = popen(pipe_in_cmd, "r");
		if (pipe_in) {
			setvbuf(pipe_in, NULL, _IONBF, 0);
			int fd = fileno(pipe_in);
			fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
		}
	}
	if (!pipe_out && pipe_out_cmd) {
		pipe_out = popen(pipe_out_cmd, "w");
		if (pipe_out) setvbuf(pipe_out, NULL, _IONBF, 0);
	}
	return (pipe_in && pipe_out) ? 0 : -1;
}

static int pipe_read_chunk(unsigned char *buf, size_t cap) {
	if (!pipe_in) return -1;
	size_t n = fread(buf, 1, cap, pipe_in);
	if (n > 0) return (int) n;
	if (ferror(pipe_in)) {
		if (errno == EAGAIN || errno == EWOULDBLOCK) { clearerr(pipe_in); return 0; }
		return -1;
	}
	return 0;
}

static int pipe_write_chunk(const unsigned char *buf, size_t len) {
	if (!pipe_out) return -1;
	return (int) fwrite(buf, 1, len, pipe_out);
}

/* The BlueALSA mode: no SCO socket of our own. The HF stack owns the link, and
 * this program only reads and writes its PCM. The PCM appears when the phone
 * starts sending call audio, so a successful open is the "accepted" event. */
static int pcm_mode_main(void) {
	char inbuf[8192];
	size_t inlen = 0;
	unsigned char chunk[CHUNK_BYTES];
	fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL, 0) | O_NONBLOCK);
	emit("{\"event\":\"listening\",\"local\":\"pcm\"}");
	int quiet_polls = 0;
	long long first_frame_at = 0;
	long long opened_at = 0;
	long long last_frame_at = 0;
	long long next_write = now_ns();
	while (running) {
		/* control channel */
		ssize_t got = read(STDIN_FILENO, inbuf + inlen, sizeof(inbuf) - inlen - 1);
		if (got > 0) {
			inlen += (size_t) got;
			inbuf[inlen] = 0;
			char *start = inbuf;
			char *nl;
			while ((nl = memchr(start, '\n', inlen - (size_t) (start - inbuf)))) {
				*nl = 0;
				if (*start) command(start);
				start = nl + 1;
				if (!running) break;
			}
			size_t used = (size_t) (start - inbuf);
			if (used) memmove(inbuf, start, inlen - used);
			inlen -= used;
		}
		else if (got == 0) {
			break;
		}

		if (!have_accepted) {
			/* The Hands-Free transport is torn down a few seconds after a call,
			 * so a handle left open from the last one goes deaf. Start over only
			 * when nothing has arrived for a while - never on a timer, which tore
			 * the transport down in the middle of a call. */
			long long now = now_ns();
			if (!pipe_mode && pcm_cap && pcm_play && now - last_frame_at > 5000000000LL
					&& now - opened_at > 5000000000LL) {
				pcm_close_pair();
				opened_at = 0;
				first_frame_at = 0;
				quiet_polls = 0;
			}
			int cap_ok, play_ok;
			if (pipe_mode) {
				cap_ok = play_ok = (backend_open() == 0);
			}
			else {
				cap_ok = pcm_open_one(&pcm_cap, SND_PCM_STREAM_CAPTURE) == 0;
				play_ok = pcm_open_one(&pcm_play, SND_PCM_STREAM_PLAYBACK) == 0;
			}
			if (cap_ok && play_ok) {
				if (!opened_at) opened_at = now_ns();
				/* An idle Hands-Free stack keeps its transport alive, so an open
				 * PCM is not a call. The first frame of audio is: the phone only
				 * sends call audio once the call is actually up. */
				int first = backend_read(chunk, sizeof(chunk));
				if (first > 0) {
					last_frame_at = now_ns();
					/* The link carries frames a moment before the phone's own
					 * audio path is fully up, and a prompt that starts then loses
					 * its first words. A frame of digital silence says the path is
					 * not up at all, so wait for one that carries something - but
					 * not forever, or a line that is genuinely quiet is never
					 * greeted. */
					if (!chunk_has_signal(chunk, (size_t) first)
						&& now_ns() - opened_at < SETTLE_WAIT_NS) {
						usleep(20000);
						continue;
					}
					if (!first_frame_at) first_frame_at = now_ns();
					downlink_chunk(chunk, (size_t) first);
					if (now_ns() - first_frame_at < SETTLE_NS) {
						usleep(20000);
						continue;
					}
					have_accepted = 1;
					quiet_polls = 0;
					emit("{\"event\":\"accepted\",\"peer\":\"pcm\"}");
				}
				else {
					long long t = now_ns();
					if (t - last_complain > 2000000000LL) {
						last_complain = t;
						int st = pcm_cap ? (int) snd_pcm_state(pcm_cap) : -1;
						char msg[96];
						snprintf(msg, sizeof(msg), "waiting for call audio (pcm state %d)", st);
						emit_error(msg);
					}
					usleep(50000);
					continue;
				}
			}
			else {
				if (pipe_mode) { if (pipe_in) { pclose(pipe_in); pipe_in = NULL; } if (pipe_out) { pclose(pipe_out); pipe_out = NULL; } }
				else { if (pcm_cap) { snd_pcm_close(pcm_cap); pcm_cap = NULL; } if (pcm_play) { snd_pcm_close(pcm_play); pcm_play = NULL; } }
				long long t = now_ns();
				if (t - last_complain > 5000000000LL) {
					last_complain = t;
					char msg[256];
					snprintf(msg, sizeof(msg), "pcm open failed: %s", pcm_error[0] ? pcm_error : "unknown");
					emit_error(msg);
				}
				usleep(200000);
				continue;
			}
		}

		int n = backend_read(chunk, sizeof(chunk));
		if (n < 0) {
			emit("{\"event\":\"closed\",\"reason\":\"pcm\"}");
			if (rec_active) record_close(1, "link");
			pcm_close_pair();
			have_accepted = 0;
			continue;
		}
		if (n > 0) {
			quiet_polls = 0;
			last_frame_at = now_ns();
			downlink_chunk(chunk, (size_t) n);
		}
		else if (n == 0 && have_accepted && ++quiet_polls > 40) {
			/* the transport stays open between calls; two seconds of nothing is
			 * the end of one */
			emit("{\"event\":\"closed\",\"reason\":\"pcm idle\"}");
			if (rec_active) record_close(1, "link");
			if (pipe_mode) { if (pipe_in) { pclose(pipe_in); pipe_in = NULL; } if (pipe_out) { pclose(pipe_out); pipe_out = NULL; } }
			else pcm_close_pair();
			have_accepted = 0;
			quiet_polls = 0;
			first_frame_at = 0;
		}

		long long t = now_ns();
		if (clip_active && t >= clip_start_at) {
			int steps = 0;
			while (t >= next_write && clip_active && steps++ < 8) {
				uplink_step(-1);
				next_write += CHUNK_NS;
			}
			/* a long stall must not be paid back as a burst: resync the clock */
			if (next_write < t - 100000000LL) next_write = t;
		}
		usleep(500);
	}
	if (rec_active) record_close(1, "quit");
	pcm_close_pair();
	return 0;
}

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--local") && i + 1 < argc) local_addr = argv[++i];
		else if (!strcmp(argv[i], "--peer") && i + 1 < argc) peer_want = argv[++i];
		else if (!strcmp(argv[i], "--loopback") && i + 1 < argc) { loopback = 1; downlink_path = argv[++i]; }
		else if (!strcmp(argv[i], "--loopback-uplink") && i + 1 < argc) uplink_path = argv[++i];
		else if (!strcmp(argv[i], "--pcm") && i + 1 < argc) pcm_dev = argv[++i];
		else if (!strcmp(argv[i], "--pipe-in") && i + 1 < argc) pipe_in_cmd = argv[++i];
		else if (!strcmp(argv[i], "--pipe-out") && i + 1 < argc) pipe_out_cmd = argv[++i];
		else if (!strcmp(argv[i], "--fast")) fast = 1;
		else if (!strcmp(argv[i], "--silence-level") && i + 1 < argc) silence_level = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--transparent")) voice = BT_VOICE_TRANSPARENT;
		else {
			fprintf(stderr,
				"usage: %s [--local BDADDR] [--peer BDADDR] [--silence-level RMS]\n"
				"          [--loopback DOWNLINK.raw [--loopback-uplink UPLINK.raw] [--fast]]\n", argv[0]);
			return 2;
		}
	}

	/* the daemon owns this process; if it goes, take the audio link with it
	 * instead of leaving a call connected to nothing */
	prctl(PR_SET_PDEATHSIG, SIGTERM);
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGPIPE, SIG_IGN);

	if (pipe_in_cmd || pipe_out_cmd) { pipe_mode = 1; return pcm_mode_main(); }
	if (pcm_dev) return pcm_mode_main();

	if (uplink_path) {
		uplink_raw = fopen(uplink_path, "wb");
		if (!uplink_raw) { perror("uplink open"); return 1; }
	}

	if (loopback) {
		sco_fd = open(downlink_path, O_RDONLY);
		if (sco_fd < 0) { perror("loopback open"); return 1; }
		emit("{\"event\":\"listening\",\"local\":\"loopback\"}");
		emit("{\"event\":\"accepted\",\"peer\":\"loopback\"}");
		have_accepted = 1;
	}
	else {
		char bound[32] = "any";
		if (local_addr) {
			listen_fd = sco_listen(local_addr, bound, sizeof(bound));
			errno = errno;
		}
		else {
			/* an unqualified SCO bind is refused when a machine has more than
			 * one controller, so each adapter is asked for its own address */
			char addresses[8][18];
			int count = addrs_from_sys(addresses, 8);
			int last_errno = 0;
			for (int i = 0; i < count && listen_fd < 0; i++) {
				listen_fd = sco_listen(addresses[i], bound, sizeof(bound));
				last_errno = errno;
			}
			if (listen_fd < 0 && count == 0) {
				listen_fd = sco_listen(NULL, bound, sizeof(bound));
				last_errno = errno;
			}
			errno = last_errno;
		}
		if (listen_fd < 0) {
			perror(local_addr ? "bind" : "bind (no adapter took the SCO listener)");
			return 1;
		}
		emit("{\"event\":\"listening\",\"local\":\"%s\"}", bound);
	}

	/* stdin is the control channel: one JSON object per line */
	char inbuf[8192];
	size_t inlen = 0;
	fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL, 0) | O_NONBLOCK);
	next_write = now_ns();

	while (running) {
		struct pollfd fds[3];
		int nfds = 0, stdin_idx = -1, sco_idx = -1, listen_idx = -1;
		fds[nfds].fd = STDIN_FILENO; fds[nfds].events = POLLIN; stdin_idx = nfds++;
		/* loopback reads its "call" from a file below, on its own schedule */
		if (sco_fd >= 0 && !loopback) { fds[nfds].fd = sco_fd; fds[nfds].events = POLLIN; sco_idx = nfds++; }
		if (listen_fd >= 0 && !have_accepted) { fds[nfds].fd = listen_fd; fds[nfds].events = POLLIN; listen_idx = nfds++; }

		long long wait_ns = 50000000LL;
		if (have_accepted && clip_active) wait_ns = next_write - now_ns();
		if (wait_ns < 0) wait_ns = 0;
		int timeout_ms = (int) (wait_ns / 1000000LL);
		if (timeout_ms > 50) timeout_ms = 50;
		if (fast && loopback) timeout_ms = 5;

		int pr = poll(fds, (nfds_t) nfds, timeout_ms);
		if (pr < 0 && errno != EINTR) { perror("poll"); break; }

		if (pr > 0 && (fds[stdin_idx].revents & (POLLIN | POLLHUP))) {
			ssize_t got = read(STDIN_FILENO, inbuf + inlen, sizeof(inbuf) - inlen - 1);
			if (got > 0) {
				inlen += (size_t) got;
				inbuf[inlen] = 0;
				char *start = inbuf;
				char *nl;
				while ((nl = memchr(start, '\n', inlen - (size_t) (start - inbuf)))) {
					*nl = 0;
					if (*start) command(start);
					start = nl + 1;
					if (!running) break;
				}
				size_t used = (size_t) (start - inbuf);
				if (used) memmove(inbuf, start, inlen - used);
				inlen -= used;
			}
			else if (got == 0) {
				/* the daemon closed its end: the call is over. A loopback probe
				 * hands its command over from a pipe that ends at once, so there
				 * the recorded file is what ends the call, not stdin. */
				if (!loopback) running = 0;
			}
		}

		/* a call can begin at any time after we listen */
		if (listen_idx >= 0 && (fds[listen_idx].revents & POLLIN)) {
			struct sockaddr_sco peer;
			socklen_t plen = sizeof(peer);
			memset(&peer, 0, sizeof(peer));
			int c = accept(listen_fd, (struct sockaddr *) &peer, &plen);
			if (c < 0) {
				/* a link that cannot be taken is the one failure that used to be
				 * silent: say who refused it, once per attempt */
				char msg[96];
				snprintf(msg, sizeof(msg), "accept failed: %s", strerror(errno));
				emit_error(msg);
			}
			if (c >= 0) {
				const char *who = peers_name(&peer);
				if (peer_want && strcasecmp(who, peer_want) != 0) {
					emit("{\"event\":\"rejected\",\"peer\":\"%s\"}", who);
					close(c);
				}
				else {
					setsockopt(c, SOL_BLUETOOTH, BT_VOICE, &voice, sizeof(voice));
					sco_fd = c;
					have_accepted = 1;
					emit("{\"event\":\"accepted\",\"peer\":\"%s\"}", who);
				}
			}
		}

		if (sco_idx >= 0 && (fds[sco_idx].revents & (POLLIN | POLLHUP | POLLERR))) {
			int rc = downlink_read(sco_fd);
			if (rc < 0) {
				emit("{\"event\":\"closed\",\"reason\":\"link\"}");
				if (rec_active) record_close(1, "link");
				break;
			}
		}

		long long t = now_ns();
		if (have_accepted && clip_active && t >= next_write) {
			int steps = 0;
			do {
				uplink_step(sco_fd);
				next_write += CHUNK_NS;
				t = now_ns();
				/* a stalled reader must not spin through the whole clip */
				if (++steps > 32) break;
			} while (fast && clip_active && t >= next_write);
			if (!fast) next_write = t + CHUNK_NS;
		}

		if (loopback) {
			/* a file stands in for the caller: it ends the call at EOF. It is
			 * drained whether or not a recording is open, so the probe always
			 * reaches the end rather than spinning on a finished clip. */
			unsigned char chunk[CHUNK_BYTES];
			int steps = 0;
			do {
				ssize_t n = read(sco_fd, chunk, sizeof(chunk));
				if (n <= 0) {
					if (rec_active) record_close(1, "link");
					emit("{\"event\":\"closed\",\"reason\":\"end of file\"}");
					running = 0;
					break;
				}
				downlink_chunk(chunk, (size_t) n);
				if (!fast) { usleep(7500); break; }
			} while (++steps < 64);
		}
	}

	if (rec_active) record_close(1, "quit");
	if (clip_active) { clip_active = 0; }
	if (uplink_raw) { fflush(uplink_raw); fclose(uplink_raw); }
	if (sco_fd >= 0 && !loopback) close(sco_fd);
	if (loopback && sco_fd >= 0) close(sco_fd);
	if (listen_fd >= 0) close(listen_fd);
	free(clip);
	return 0;
}
