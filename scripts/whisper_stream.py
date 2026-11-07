#!/usr/bin/env python3
"""The caller's half of a screened call, as text, while it is happening.

The audio helper (perl/sco/sco_helper.c, --tee) copies every frame of the
caller's voice into a FIFO. This reads that FIFO, finds where a sentence starts
and stops, and prints one JSON object per line:

    {"event": "ready"}                       reading now
    {"event": "partial", "text": "may i"}    still being said
    {"event": "line", "text": "may i ask whose calling", "ms": 2400}
    {"event": "error", "message": "..."}     then exit

The sentence is handed to the warm whisper.cpp server on loopback (POST
/inference, response_format=json, language auto); when that server is not up
the one-shot whisper-cli is used instead. Both keep the JSON protocol the
gateway already reads, so the gateway only needs a new command, not a new
reader.

Segmentation is an energy VAD over 100 ms windows: speech has to hold 300 ms to
open a line, 700 ms of silence closes it, 1 s is the least that is worth asking
the model about, and a line is capped at 15 s. The room's own noise is measured
first, exactly as the helper measures it for the recorded name, so narrowband
hiss does not read as speech. Nothing here writes to stdout except that JSON.
Diagnostics go to stderr.
"""

import argparse
import array
import http.client
import io
import json
import math
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import uuid
import wave

WINDOW = 0.1
RATE = 16000


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def rms16(buf):
    """RMS of one window of signed 16-bit little-endian samples."""
    samples = array.array("h")
    samples.frombytes(buf[: len(buf) - (len(buf) % 2)])
    if not samples:
        return 0.0
    total = 0.0
    for value in samples:
        total += float(value) * float(value)
    return math.sqrt(total / len(samples))


def upsample2(buf):
    """8 kHz s16le to 16 kHz s16le, a sample between each pair."""
    src = array.array("h")
    src.frombytes(buf[: len(buf) - (len(buf) % 2)])
    count = len(src)
    out = array.array("h", bytes(4 * count))
    for i in range(count):
        value = src[i]
        out[2 * i] = value
        out[2 * i + 1] = value if i + 1 >= count else (value + src[i + 1]) // 2
    return out.tobytes()


def clean(text):
    return " ".join((text or "").replace("\r", " ").replace("\n", " ").split())


def stock_silence(text):
    """A line that is only whisper's stock answer to a quiet clip is silence."""
    bare = (text or "").lower()
    bare = " ".join(part for part in bare.replace("[", " ").replace("]", " ").split())
    bare = "".join(ch if ch.isalnum() or ch in "' " else " " for ch in bare)
    bare = " ".join(bare.split())
    if not bare:
        return True
    stock = {
        "thank you", "thanks", "thank you very much", "thanks very much",
        "thank you so much", "thanks a lot", "many thanks", "thank you thank you",
        "thank you for watching", "thanks for watching",
        "thank you for watching everyone", "thanks for watching everyone",
        "please subscribe", "please like and subscribe", "like and subscribe",
        "subscribe to my channel", "please subscribe to my channel",
        "you", "bye", "bye bye", "goodbye", "the end", "that is it",
    }
    return bare in stock


def installed_root():
    return os.environ.get("JAWNOS_WHISPER_DIR") or os.path.join(
        os.path.expanduser("~"), ".local/share/jawnos/whisper")


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
    for base in (os.path.join(installed_root(), "models"), os.path.expanduser("~/whisper.cpp/models")):
        for name in (arg, "ggml-%s.bin" % arg):
            path = os.path.join(base, name)
            if os.path.isfile(path):
                return path
    raise SystemExit("whisper: no model at %s" % arg)


def cli_bin():
    env = os.environ.get("JAWNOS_WHISPER_CLI")
    if env and os.access(env, os.X_OK):
        return env
    candidates = (
        os.path.join(installed_root(), "whisper-cli"),
        os.path.join(installed_root(), "venv/bin/whisper-cli"),
        os.path.expanduser("~/whisper.cpp/build/bin/whisper-cli"),
    )
    for path in candidates:
        if os.access(path, os.X_OK):
            return path
    return shutil.which("whisper-cli") or ""


def pcm_to_wav(pcm):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(pcm)
    return buf.getvalue()


def server_text(pcm, language, timeout, host, port):
    """The warm server's answer, or None when it is not answering."""
    boundary = "----jawnos" + uuid.uuid4().hex
    body = bytearray()

    def field(name, value):
        body.extend(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                     % (boundary, name, value)).encode("utf-8"))

    body.extend(("--%s\r\nContent-Disposition: form-data; name=\"file\"; "
                 "filename=\"segment.wav\"\r\nContent-Type: audio/wav\r\n\r\n" % boundary).encode("utf-8"))
    body.extend(pcm_to_wav(pcm))
    body.extend(b"\r\n")
    field("response_format", "json")
    if language and language != "auto":
        field("language", language)
    body.extend(("--%s--\r\n" % boundary).encode("utf-8"))
    try:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
        conn.request("POST", "/inference", bytes(body), {
            "Content-Type": "multipart/form-data; boundary=" + boundary,
            "Content-Length": str(len(body)),
        })
        response = conn.getresponse()
        raw = response.read()
        conn.close()
        if response.status != 200:
            return None
        data = json.loads(raw.decode("utf-8", "replace"))
        return data.get("text", "")
    except Exception:
        return None


def cli_text(pcm, model, language, timeout):
    binary = cli_bin()
    if not binary or not model:
        return ""
    cmd = [binary, "-m", model, "--output-txt", "--file", "-"]
    if language and language != "auto":
        cmd += ["-l", language]
    try:
        run = subprocess.run(cmd, input=pcm_to_wav(pcm), stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=timeout)
    except Exception:
        return ""
    if run.returncode != 0:
        return ""
    return run.stdout.decode("utf-8", "replace")


class Segmenter:
    """Where a sentence begins and ends in a stream of 16 kHz windows."""

    def __init__(self, pause_s, min_s, open_s, ceiling_s):
        self.pause_windows = max(1, int(round(pause_s / WINDOW)))
        self.min_windows = max(1, int(round(min_s / WINDOW)))
        self.open_windows = max(1, int(round(open_s / WINDOW)))
        self.ceiling_windows = max(self.min_windows, int(round(ceiling_s / WINDOW)))
        self.room = []
        self.floor = 0.0
        self.room_read = False
        self.heard = False
        self.run = 0
        self.prewindow = []
        self.buffer = []
        self.carry = []
        self.speech = 0
        self.pause = 0
        self.peak = 0.0
        self.opened_at = 0.0
        self.last_partial = 0.0

    def margin(self):
        floor = self.floor if self.floor > 0 else 655.0
        return max(floor * 0.5, 491.0)

    def onset(self):
        return self.margin() * 1.5

    def learn(self, level):
        if not self.room_read:
            self.room.append(level)
            if len(self.room) >= 5:
                self.floor = min(self.room)
                self.room_read = True
            return
        if level < self.floor or self.floor <= 0:
            self.floor = level if self.floor <= 0 else (self.floor * 0.9 + level * 0.1)

    def feed(self, window, level, now):
        events = []
        if not self.room_read:
            self.learn(level)
            return events
        if not self.heard:
            if level <= self.floor + self.onset():
                self.run = 0
                self.prewindow.append(window)
                self.prewindow = self.prewindow[-3:]
                self.learn(level)
                return events
            self.run += 1
            self.prewindow.append(window)
            self.prewindow = self.prewindow[-4:]
            if self.run < self.open_windows:
                return events
            self.heard = True
            self.buffer = list(self.prewindow)
            self.prewindow = []
            self.speech = 0
            self.pause = 0
            self.peak = 0.0
            self.opened_at = now - len(self.buffer) * WINDOW
            self.last_partial = now
            events.append(("open",))
            return events
        self.buffer.append(window)
        if level > self.peak:
            self.peak = level
        quiet = level <= self.floor + self.margin()
        hushed = self.peak > 655.0 and level * 3.5 < self.peak
        if not quiet and not hushed:
            self.pause = 0
            self.speech += 1
        else:
            self.pause += 1
        total = len(self.buffer) * WINDOW
        if total >= 1.0 and now - self.last_partial >= 1.2:
            self.last_partial = now
            events.append(("partial", b"".join(self.buffer)))
        if self.pause >= self.pause_windows:
            # Close even a short burst: finish() holds it for the next sentence
            # instead of leaving the line open until the ceiling.
            events.append(self.finish("pause"))
        elif len(self.buffer) >= self.ceiling_windows:
            events.append(self.finish("length"))
        return events

    def finish(self, why):
        audio = b"".join(self.buffer)
        duration_ms = int(round(len(self.buffer) * WINDOW * 1000))
        short = len(self.buffer) < self.min_windows
        if short:
            # Too little to ask the model about: hold it and prepend it to the
            # next sentence rather than posting a clip on its own.
            self.carry = (self.carry + self.buffer)[-self.min_windows * 2:]
            result = ("carry", b"", duration_ms, why)
        else:
            if self.carry:
                audio = b"".join(self.carry) + audio
                duration_ms += int(round(len(self.carry) * WINDOW * 1000))
                self.carry = []
            result = ("line", audio, duration_ms, why)
        self.heard = False
        self.run = 0
        self.peak = 0.0
        self.speech = 0
        self.pause = 0
        self.buffer = []
        self.prewindow = []
        return result


def main():
    parser = argparse.ArgumentParser(description="Live whisper.cpp transcript of a screened call")
    parser.add_argument("--fifo", required=True, help="the helper's --tee FIFO")
    parser.add_argument("--model", required=True, help="a model directory or ggml file")
    parser.add_argument("--rate", type=int, default=8000, help="the FIFO's sample rate")
    parser.add_argument("--pause", type=float, default=0.7, help="silence that ends a line")
    parser.add_argument("--min", type=float, default=1.0, help="audio a line must hold")
    parser.add_argument("--open", type=float, default=0.3, help="speech that opens a line")
    parser.add_argument("--ceiling", type=float, default=15.0, help="longest single line")
    parser.add_argument("--language", default="auto", help="a language code or auto")
    parser.add_argument("--server-host", default="127.0.0.1")
    parser.add_argument("--server-port", type=int, default=8178)
    parser.add_argument("--no-partial", action="store_true", help="omit the sentence being said")
    args = parser.parse_args()

    try:
        model = resolve_model(args.model)
    except SystemExit as exc:
        emit({"error": str(exc)})
        return 2

    state = {"lock": threading.Lock(), "seq": 0, "last_partial": "",
             "server_ok": True, "retry_at": 0.0}
    line_q = queue.Queue()
    partial_q = queue.Queue(maxsize=1)

    def line_worker():
        while True:
            job = line_q.get()
            if job is None:
                line_q.task_done()
                break
            _seq, audio, ms, why = job
            with state["lock"]:
                try_server = state["server_ok"] and time.monotonic() >= state["retry_at"]
            text = None
            if try_server:
                text = server_text(audio, args.language, 30, args.server_host, args.server_port)
                with state["lock"]:
                    if text is None:
                        state["server_ok"] = False
                        state["retry_at"] = time.monotonic() + 30
                    else:
                        state["server_ok"] = True
            if text is None:
                text = cli_text(audio, model, args.language, 120)
            text = clean(text)
            if text and not stock_silence(text):
                emit({"event": "line", "text": text, "ms": ms, "why": why})
            else:
                emit({"event": "partial", "text": ""})
            line_q.task_done()

    def partial_worker():
        while True:
            job = partial_q.get()
            if job is None:
                break
            seq, audio = job
            with state["lock"]:
                if state["seq"] != seq or not state["server_ok"] or time.monotonic() < state["retry_at"]:
                    continue
            text = server_text(audio, args.language, 10, args.server_host, args.server_port)
            if text is None:
                with state["lock"]:
                    state["server_ok"] = False
                    state["retry_at"] = time.monotonic() + 30
                continue
            text = clean(text)
            if not text or stock_silence(text):
                continue
            with state["lock"]:
                if state["seq"] != seq or state["last_partial"] == text:
                    continue
                state["last_partial"] = text
            emit({"event": "partial", "text": text})

    threading.Thread(target=line_worker, daemon=True).start()
    if not args.no_partial:
        threading.Thread(target=partial_worker, daemon=True).start()

    # The SCO link is 8 kHz; a 16 kHz FIFO needs no resample. Any other rate
    # goes through ffmpeg once, before segmentation, so the windows stay 100 ms.
    direct = None
    if args.rate == RATE or args.rate * 2 == RATE:
        direct = args.rate
    filt = None
    if direct is None:
        try:
            filt = subprocess.Popen(
                ["ffmpeg", "-nostdin", "-loglevel", "error",
                 "-f", "s16le", "-ar", str(args.rate), "-ac", "1", "-i", "pipe:0",
                 "-f", "s16le", "-ar", str(RATE), "-ac", "1", "pipe:1"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        except Exception as exc:
            emit({"error": "ffmpeg is needed to resample a %d Hz call: %s" % (args.rate, exc)})
            return 4

    try:
        fifo = os.open(args.fifo, os.O_RDONLY)
    except Exception as exc:
        emit({"error": "could not open %s: %s" % (args.fifo, exc)})
        return 3

    if filt is not None:
        def pump():
            try:
                while True:
                    data = os.read(fifo, 4096)
                    if not data:
                        break
                    filt.stdin.write(data)
                    filt.stdin.flush()
            except Exception:
                pass
            try:
                filt.stdin.close()
            except Exception:
                pass
        threading.Thread(target=pump, daemon=True).start()

    emit({"event": "ready"})
    seg = Segmenter(args.pause, args.min, args.open, args.ceiling)
    window_bytes = int(RATE * WINDOW) * 2

    def handle(events, now):
        for event in events:
            if event[0] == "partial":
                with state["lock"]:
                    seq = state["seq"]
                try:
                    partial_q.put_nowait((seq, event[1]))
                except queue.Full:
                    pass
            elif event[0] == "line":
                _kind, audio, ms, why = event
                with state["lock"]:
                    state["seq"] += 1
                    seq = state["seq"]
                    state["last_partial"] = ""
                line_q.put((seq, audio, ms, why))

    try:
        if direct is not None:
            raw_bytes = int(direct * WINDOW) * 2
            pending = b""
            while True:
                data = os.read(fifo, 8192)
                if not data:
                    break
                pending += data
                while len(pending) >= raw_bytes:
                    raw = pending[:raw_bytes]
                    pending = pending[raw_bytes:]
                    window = raw if direct == RATE else upsample2(raw)
                    handle(seg.feed(window, rms16(raw), time.monotonic()), time.monotonic())
        else:
            pending = b""
            while True:
                data = filt.stdout.read(4096)
                if not data:
                    break
                pending += data
                while len(pending) >= window_bytes:
                    window = pending[:window_bytes]
                    pending = pending[window_bytes:]
                    handle(seg.feed(window, rms16(window), time.monotonic()), time.monotonic())
    finally:
        if seg.heard:
            event = seg.finish("end")
            if event[0] == "line":
                with state["lock"]:
                    state["seq"] += 1
                    seq = state["seq"]
                line_q.put((seq, event[1], event[2], event[3]))
        try:
            os.close(fifo)
        except Exception:
            pass
        if filt is not None:
            try:
                filt.wait(timeout=2)
            except Exception:
                try:
                    filt.kill()
                except Exception:
                    pass
        # Let a finished line leave before the process does; a live call's
        # reader is killed, and losing that last partial is harmless.
        line_q.put(None)
        line_q.join()
        partial_q.put(None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
