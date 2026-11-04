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

#include <bluetooth/bluetooth.h>
#include <bluetooth/hci.h>
#include <bluetooth/hci_lib.h>
#include <bluetooth/sco.h>

#define RATE 8000
#define CHUNK_SAMPLES 60                 /* 7.5 ms of 8 kHz s16le */
#define CHUNK_BYTES (CHUNK_SAMPLES * 2)
#define BYTES_PER_MS (RATE * 2 / 1000)
#define CHUNK_NS 7500000LL

static volatile sig_atomic_t running = 1;
static int sco_fd = -1, listen_fd = -1;
static const char *local_addr = NULL;
static const char *peer_want = NULL;
static int voice = BT_VOICE_CVSD_16BIT;
static int silence_level = 400;
static int loopback = 0, fast = 0;
static const char *downlink_path = NULL, *uplink_path = NULL;
static FILE *uplink_raw = NULL;
static int have_accepted = 0;

/* ---- uplink clip ------------------------------------------------------- */

static unsigned char *clip = NULL;
static size_t clip_len = 0, clip_pos = 0;
static int clip_id = 0;
static long clip_ms = 0;
static int clip_active = 0;
static long long next_write = 0;
static long long now_ns(void);

/* ---- recording --------------------------------------------------------- */

static FILE *rec_file = NULL;
static char rec_path[PATH_MAX];
static long rec_bytes = 0, rec_total_ms = 0, rec_silence_bytes = 0;
static long rec_want_ms = 0, rec_silence_ms = 1200, rec_min_ms = 400;
static int rec_id = 0, rec_active = 0, rec_quiet = 0;

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
	rec_quiet = (strcmp(reason, "silence") == 0);
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
	rec_bytes = rec_total_ms = rec_silence_bytes = 0;
	rec_want_ms = want_ms > 0 ? want_ms : 0;
	rec_silence_ms = silence_ms > 0 ? silence_ms : 0;
	rec_min_ms = min_ms > 0 ? min_ms : 0;
	rec_id = id;
	rec_active = 1;
	emit("{\"event\":\"recording\",\"id\":%d}", id);
}

/* ---- downlink ----------------------------------------------------------- */

/* Write one 7.5 ms chunk of the caller's voice, and decide when the clip has
 * ended. Silence is measured per frame (RMS) and only counts once min_ms has
 * passed, so a breath before the name does not cut the recording. */
static void downlink_chunk(const unsigned char *buf, size_t len) {
	if (len > CHUNK_BYTES) len = CHUNK_BYTES;
	if (rec_active) {
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
		long rms = n ? (long) (sqrt((double) sum / n)) : 0;
		if (rms < silence_level) rec_silence_bytes += (long) len;
		else rec_silence_bytes = 0;
		if (rec_want_ms && rec_total_ms >= rec_want_ms) record_close(1, "length");
		else if (rec_silence_ms && rec_silence_bytes >= rec_silence_ms * BYTES_PER_MS
			&& rec_total_ms >= rec_min_ms)
			record_close(1, "silence");
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
	next_write = now_ns();
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
		/* a quarter of full scale: audible in a call without clipping */
		int16_t v = (int16_t) (sin(2.0 * 3.141592653589793 * hz * t) * 8000);
		clip[i * 2] = (unsigned char) (v & 0xff);
		clip[i * 2 + 1] = (unsigned char) ((v >> 8) & 0xff);
	}
	clip_len = samples * 2;
	clip_pos = 0;
	clip_id = id;
	clip_ms = 0;
	clip_active = 1;
	next_write = now_ns();
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
			ssize_t w = write(fd, clip + clip_pos, take);
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

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--local") && i + 1 < argc) local_addr = argv[++i];
		else if (!strcmp(argv[i], "--peer") && i + 1 < argc) peer_want = argv[++i];
		else if (!strcmp(argv[i], "--loopback") && i + 1 < argc) { loopback = 1; downlink_path = argv[++i]; }
		else if (!strcmp(argv[i], "--loopback-uplink") && i + 1 < argc) uplink_path = argv[++i];
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
				/* the daemon closed its end: the call is over */
				running = 0;
			}
		}

		/* a call can begin at any time after we listen */
		if (listen_idx >= 0 && (fds[listen_idx].revents & POLLIN)) {
			struct sockaddr_sco peer;
			socklen_t plen = sizeof(peer);
			memset(&peer, 0, sizeof(peer));
			int c = accept(listen_fd, (struct sockaddr *) &peer, &plen);
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

		if (loopback && rec_active) {
			/* a file stands in for the caller: it ends the call at EOF, and it
			 * only advances while something is listening to the downlink */
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
			} while (rec_active && ++steps < 64);
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
