#!/usr/bin/env python3
"""A resident, demand-started Piper voice for spoken replies.

piper the CLI loads its voice model on every invocation: a short reply pays that
load again each time (about 3 s on an ARM homebase). The Python wheel's `piper`
CLI also exits after one stdin line, so it cannot be kept as a warm process.
This daemon loads `PiperVoice` once and answers loopback HTTP with 8 kHz mono
s16le PCM, exactly what the reply paths already stream.

It is loopback-only, started by demand (President's 'piper server' loop or a
say.warm Crew job on a peer), and stops itself after ten quiet minutes or a hard
maximum age. The manager chooses it when the venv can import piper; a machine
with a native piper but no Python venv keeps the Perl CLI daemon
(scripts/piper_server.pl) instead. A machine with no piper never starts either.

  GET  /health   -> {"ok":1,"pid":...,"model":...,"port":...,"started":...}
  POST /render   -> 8 kHz mono s16le PCM (body is UTF-8 text)
  POST /shutdown -> stop after replying
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import wave
from http.server import BaseHTTPRequestHandler, HTTPServer

STOP = False
VOICE = None
MODEL = ""
PORT = 8179
LOG = None
SPOOL = None
STARTED = time.time()
LAST_USE = time.time()


def log(message):
    if not LOG:
        return
    try:
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(time.strftime("[%Y-%m-%d %H:%M:%S] ") + message + "\n")
    except OSError:
        pass


def health_body():
    return json.dumps({
        "ok": 1,
        "pid": os.getpid(),
        "model": MODEL,
        "port": PORT,
        "started": int(STARTED),
    }).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        return

    def _send(self, code, ctype, body=b"", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.close_connection = True

    def _path(self):
        return self.path.split("?", 1)[0]

    def do_GET(self):
        global STOP
        path = self._path()
        if path == "/health":
            self._send(200, "application/json", health_body())
        elif path == "/shutdown":
            STOP = True
            self._send(200, "text/plain", b"bye\n")
        else:
            self._send(404, "text/plain", b"unknown path\n")

    def do_POST(self):
        global STOP, LAST_USE
        path = self._path()
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length < 0 or length > 4_000_000:
            self._send(400, "text/plain", b"bad length\n")
            return
        body = self.rfile.read(length) if length else b""
        if path == "/health":
            self._send(200, "application/json", health_body())
            return
        if path == "/shutdown":
            STOP = True
            self._send(200, "text/plain", b"bye\n")
            return
        if path != "/render":
            self._send(404, "text/plain", b"unknown path\n")
            return
        text = body.decode("utf-8", "replace").strip()
        if not text:
            self._send(400, "text/plain", b"render needs text\n")
            return
        if len(text) > 4000:
            self._send(413, "text/plain", b"render text is too long\n")
            return
        try:
            started = time.time()
            wav_path = os.path.join(SPOOL, "render-%d.wav" % int(time.time() * 1000))
            with wave.open(wav_path, "wb") as wav_file:
                VOICE.synthesize_wav(text, wav_file)
            converted = subprocess.run(
                ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", wav_path,
                 "-f", "s16le", "-ar", "8000", "-ac", "1", "-"],
                capture_output=True, timeout=30,
            )
            try:
                os.unlink(wav_path)
            except OSError:
                pass
            if converted.returncode != 0 or not converted.stdout:
                raise RuntimeError("ffmpeg produced nothing")
            self._send(200, "application/octet-stream", converted.stdout,
                       {"X-Piper-Model": MODEL})
            LAST_USE = time.time()
            log("render %d bytes in %dms" % (len(converted.stdout),
                                              (time.time() - started) * 1000))
        except Exception as error:  # noqa: BLE001 - report and let the caller fall back
            log("render failed: %s" % error)
            self._send(503, "text/plain", b"piper produced nothing\n")
            STOP = True


def main():
    global VOICE, MODEL, PORT, LOG, SPOOL, STOP
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--port", type=int, default=8179)
    parser.add_argument("--idle", type=int, default=600)
    parser.add_argument("--max-age", type=int, default=3600)
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--log", default="")
    parser.add_argument("--espeak-data", default="")
    args = parser.parse_args()

    MODEL = args.model
    PORT = args.port
    LOG = args.log or None
    SPOOL = tempfile.mkdtemp(prefix="piper-warm-")

    # Bind before the model loads: a second daemon (the demand loop and a
    # say.warm can race) exits here without paying another model load.
    try:
        server = HTTPServer(("127.0.0.1", PORT), Handler)
    except OSError as error:
        log("could not listen on 127.0.0.1:%d: %s" % (PORT, error))
        return 1

    try:
        from piper import PiperVoice
        kwargs = {}
        config = MODEL + ".json"
        if os.path.exists(config):
            kwargs["config_path"] = config
        if args.espeak_data:
            kwargs["espeak_data_dir"] = args.espeak_data
        VOICE = PiperVoice.load(MODEL, **kwargs)
    except Exception as error:  # noqa: BLE001 - the manager falls back to one-shot
        log("piper did not start: %s" % error)
        server.server_close()
        return 1

    log("started pid=%d port=%d model=%s" % (os.getpid(), PORT, MODEL))
    server.timeout = 1
    while not STOP:
        server.handle_request()
        now = time.time()
        if now - LAST_USE > args.idle:
            log("stopping after %ds idle" % args.idle)
            break
        if args.max_age and now - STARTED > args.max_age:
            log("stopping at the hard maximum age")
            break
    server.server_close()
    log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
