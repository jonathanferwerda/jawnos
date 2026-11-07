#!/usr/bin/env python3
"""whisper.cpp's command line and warm server, over the pywhispercpp wheel.

The pip wheel ships libwhisper but not the whisper-cli or whisper-server
programs. This file is both, so scripts/jawnos_deps.pl can install the engine
from a wheel with no cmake and no sudo:

    whisper_tool.py cli    -m MODEL -f FILE [-l LANG] [--output-txt]
    whisper_tool.py server -m MODEL [--host H] [--port N]

`cli` prints the transcript on stdout and takes the flags JawnOS already used
(-m, -f/--file - for stdin, -l, --output-txt). `server` speaks the whisper.cpp
HTTP shape on /inference: a multipart `file`, an optional `language` and
`response_format`, and {"text": ...} back. ffmpeg decodes and resamples to the
16 kHz the model wants, so any container a call or a microphone produces works.
"""

import argparse
import json
import os
import subprocess
import sys
import threading
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RATE = 16000


def installed_root():
    return os.environ.get("JAWNOS_WHISPER_DIR") or os.path.join(
        os.path.expanduser("~"), ".local/share/jawnos/whisper")


def models_dir():
    return os.environ.get("JAWNOS_WHISPER_MODELS") or os.path.join(installed_root(), "models")


def resolve_model(arg):
    """A model file, a model directory, or a bare name under the installed tree."""
    arg = arg or "base"
    if os.path.isdir(arg):
        for name in ("ggml-base.bin", "ggml-tiny.bin"):
            path = os.path.join(arg, name)
            if os.path.isfile(path):
                return path
        for name in sorted(os.listdir(arg)):
            if name.startswith("ggml-") and name.endswith(".bin"):
                return os.path.join(arg, name)
    elif os.path.isfile(arg):
        return arg
    for base in (models_dir(), os.path.expanduser("~/whisper.cpp/models")):
        for name in (arg, "ggml-%s.bin" % arg):
            path = os.path.join(base, name)
            if os.path.isfile(path):
                return path
    raise SystemExit("whisper: no model at %s" % arg)


def load_model(path, threads=None):
    from pywhispercpp.model import Model
    return Model(
        path,
        n_threads=max(1, threads or min(4, os.cpu_count() or 1)),
        redirect_whispercpp_logs_to=None,
        print_progress=False,
        print_realtime=False,
        print_timestamps=False,
    )


def decode_audio(source, data=None):
    """Any ffmpeg-readable audio to 16 kHz mono float32; bytes or a path."""
    import numpy as np
    cmd = ["ffmpeg", "-nostdin", "-loglevel", "error"]
    cmd += ["-i", "pipe:0"] if data is not None else ["-i", source]
    cmd += ["-f", "f32le", "-ar", str(RATE), "-ac", "1", "pipe:1"]
    run = subprocess.run(cmd, input=data, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, check=False)
    if run.returncode != 0:
        why = (run.stderr or b"ffmpeg failed").decode("utf-8", "replace").strip()
        raise RuntimeError(why)
    return np.frombuffer(run.stdout, dtype=np.float32)


def clean(text):
    return " ".join((text or "").replace("\r", " ").replace("\n", " ").split())


def transcribe(model, audio, language=None):
    # whisper.cpp treats 'auto' as detect; that is the house default for a call.
    segments = model.transcribe(audio, language=language or "auto")
    return clean(" ".join(getattr(segment, "text", "") for segment in segments))


def main_cli(argv):
    parser = argparse.ArgumentParser(prog="whisper-cli",
                                     description="whisper.cpp command line over pywhispercpp")
    parser.add_argument("-m", "--model", required=True)
    parser.add_argument("-f", "--file", default="-")
    parser.add_argument("-l", "--language", default="auto")
    parser.add_argument("-t", "--threads", type=int)
    parser.add_argument("--output-txt", action="store_true")
    parser.add_argument("-otxt", action="store_true", dest="output_txt_short")
    parser.add_argument("-nt", "--no-timestamps", action="store_true")
    parser.add_argument("--no-prints", action="store_true")
    args, _unknown = parser.parse_known_args(argv)
    model = load_model(resolve_model(args.model), args.threads)
    if args.file == "-":
        audio = decode_audio(None, sys.stdin.buffer.read())
    else:
        audio = decode_audio(args.file)
    print(transcribe(model, audio, args.language))
    return 0


def multipart_parts(content_type, body):
    header = ("Content-Type: %s\r\nMIME-Version: 1.0\r\n\r\n" % content_type).encode("latin-1")
    message = BytesParser(policy=policy.default).parsebytes(header + body)
    parts = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name:
            parts[name] = part.get_payload(decode=True) or b""
    return parts


def main_server(argv):
    parser = argparse.ArgumentParser(prog="whisper-server",
                                     description="whisper.cpp HTTP server over pywhispercpp")
    parser.add_argument("-m", "--model", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8178)
    parser.add_argument("-l", "--language", default="auto")
    parser.add_argument("-t", "--threads", type=int)
    parser.add_argument("--convert", action="store_true")
    args = parser.parse_args(argv)
    model = load_model(resolve_model(args.model), args.threads)
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *unused):
            pass

        def reply(self, code, payload, ctype="application/json"):
            body = payload if isinstance(payload, bytes) else payload.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self.reply(200, json.dumps({"status": "ok"}))

        def do_POST(self):
            if not self.path.startswith("/inference"):
                self.reply(404, json.dumps({"error": "not found"}))
                return
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            ctype = self.headers.get("Content-Type") or ""
            language = args.language
            fmt = "json"
            try:
                if ctype.startswith("multipart/form-data"):
                    parts = multipart_parts(ctype, body)
                    data = parts.get("file")
                    if not data:
                        raise RuntimeError("no file in the request")
                    language = (parts.get("language") or b"").decode("utf-8", "ignore") or language
                    fmt = (parts.get("response_format") or b"").decode("utf-8", "ignore") or fmt
                elif ctype.startswith("audio/"):
                    data = body
                else:
                    raise RuntimeError("send a multipart file")
                audio = decode_audio(None, data)
                with lock:
                    text = transcribe(model, audio, language)
                if fmt == "text":
                    self.reply(200, text, "text/plain; charset=utf-8")
                else:
                    self.reply(200, json.dumps({"text": text}, ensure_ascii=False))
            except Exception as exc:
                self.reply(500, json.dumps({"error": str(exc)}))

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print("whisper-server: %s:%d" % (args.host, args.port), file=sys.stderr, flush=True)
    server.serve_forever()
    return 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("cli", "server"):
        print("usage: whisper_tool.py {cli|server} ...", file=sys.stderr)
        return 2
    if sys.argv[1] == "cli":
        return main_cli(sys.argv[2:])
    return main_server(sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
