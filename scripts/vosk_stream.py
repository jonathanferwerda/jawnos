#!/usr/bin/env python3
"""The caller's half of a screened call, as text, while it is happening.

The audio helper (perl/sco/sco_helper.c, --tee) copies every frame of the
caller's voice into a FIFO. This reads that FIFO, resamples it to the 16 kHz
Vosk wants, finds where a sentence starts and stops, and prints one JSON object
per line:

    {"event": "ready"}                       the model is loaded, reading now
    {"event": "partial", "text": "may i"}    still being said
    {"event": "line", "text": "may i ask whose calling", "ms": 2400}
    {"event": "error", "message": "..."}     then exit

A line is emitted when the caller has paused long enough to read as the end of
a sentence (--pause, 0.7 s) and has said something (--min, 0.4 s). One
recogniser is made per sentence, so a line never carries the last one's words.

The room's own noise is measured first, exactly as the helper measures it for
the recorded name: speech has to hold three windows before it counts, and the
pause is judged against the room rather than a fixed level. That matters on a
narrowband SCO link, whose hiss sits above any threshold that reads as silence.

Nothing here writes to stdout except that JSON. Diagnostics go to stderr.
"""

import argparse
import array
import json
import math
import os
import subprocess
import sys
import threading
import time

WINDOW_SECONDS = 0.1


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
    """8 kHz s16le to 16 kHz s16le, a sample between each pair.

    The SCO link is 8 kHz and Vosk's model wants 16 kHz; linear interpolation is
    enough for speech here and keeps the resample in this process, where a
    second pipe would add a few milliseconds to every line.
    """
    src = array.array("h")
    src.frombytes(buf[: len(buf) - (len(buf) % 2)])
    count = len(src)
    out = array.array("h", bytes(4 * count))
    for i in range(count):
        value = src[i]
        out[2 * i] = value
        out[2 * i + 1] = value if i + 1 >= count else (value + src[i + 1]) // 2
    return out.tobytes()


def load_model(path):
    try:
        from vosk import Model, KaldiRecognizer, SetLogLevel
    except Exception as exc:  # noqa: BLE001
        emit({"error": "vosk is not installed: %s" % exc})
        return None, None
    SetLogLevel(-1)
    try:
        model = Model(path)
    except Exception as exc:  # noqa: BLE001
        emit({"error": "vosk model %s: %s" % (path, exc)})
        return None, None
    return model, KaldiRecognizer


def pump(fd, sink):
    """Copy the FIFO into ffmpeg's stdin until the helper closes it."""
    try:
        while True:
            data = os.read(fd, 4096)
            if not data:
                break
            sink.write(data)
            sink.flush()
    except Exception:
        pass
    try:
        sink.close()
    except Exception:
        pass


class Segmenter:
    """Where a sentence begins and ends in a stream of 16 kHz windows."""

    def __init__(self, model, KaldiRecognizer, pause_s, min_s, ceiling_s):
        self.model = model
        self.Kaldi = KaldiRecognizer
        self.pause_windows = max(1, int(round(pause_s / WINDOW_SECONDS)))
        self.min_windows = max(1, int(round(min_s / WINDOW_SECONDS)))
        self.ceiling_windows = max(self.min_windows, int(round(ceiling_s / WINDOW_SECONDS)))
        self.room = []
        self.floor = 0.0
        self.room_read = False
        self.heard = False
        self.run = 0
        self.peak = 0.0
        self.speech = 0
        self.pause = 0
        self.windows = 0
        self.pre_roll = []
        self.rec = None
        self.last_partial = ""
        self.opened_at = 0.0

    # -- the room ---------------------------------------------------------
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
        # a quieter window slowly lowers the floor; a louder one is speech
        if level < self.floor or self.floor <= 0:
            self.floor = level if self.floor <= 0 else (self.floor * 0.9 + level * 0.1)

    # -- sentences --------------------------------------------------------
    def begin(self):
        self.heard = True
        self.run = 0
        self.peak = 0.0
        self.speech = 0
        self.pause = 0
        self.windows = 0
        self.last_partial = ""
        self.opened_at = time.monotonic()
        self.rec = self.Kaldi(self.model, 16000)
        try:
            self.rec.SetWords(False)
        except Exception:
            pass
        # the frames just before onset carry the start of the first word
        for window in self.pre_roll:
            self.rec.AcceptWaveform(window)
        self.pre_roll = []

    def feed(self, window, level):
        if not self.room_read:
            self.learn(level)
            return
        if not self.heard:
            if level <= self.floor + self.onset():
                self.run = 0
                self.pre_roll.append(window)
                self.pre_roll = self.pre_roll[-3:]
                self.learn(level)
                return
            self.run += 1
            self.pre_roll.append(window)
            self.pre_roll = self.pre_roll[-4:]
            if self.run < 3:
                return
            self.begin()
            return
        # a sentence is open
        self.windows += 1
        if level > self.peak:
            self.peak = level
        self.rec.AcceptWaveform(window)
        quiet = level <= self.floor + self.margin()
        hushed = self.peak > 655.0 and level * 3.5 < self.peak
        if not quiet and not hushed:
            self.pause = 0
            self.speech += 1
        else:
            self.pause += 1
        self.partial()
        if self.pause >= self.pause_windows and self.speech >= self.min_windows:
            self.finish("pause")
        elif self.windows >= self.ceiling_windows:
            self.finish("length")

    def partial(self):
        try:
            part = json.loads(self.rec.PartialResult()).get("partial", "").strip()
        except Exception:
            return
        if part and part != self.last_partial:
            self.last_partial = part
            emit({"event": "partial", "text": part})

    def finish(self, why):
        if self.rec is None:
            return
        try:
            text = json.loads(self.rec.FinalResult()).get("text", "").strip()
        except Exception:
            text = ""
        elapsed = int(round((time.monotonic() - self.opened_at) * 1000))
        if text:
            emit({"event": "line", "text": text, "ms": elapsed, "why": why})
        self.rec = None
        self.heard = False
        self.run = 0
        self.peak = 0.0
        self.speech = 0
        self.pause = 0
        self.windows = 0
        self.last_partial = ""


def main():
    parser = argparse.ArgumentParser(description="Live Vosk transcript of a screened call")
    parser.add_argument("--fifo", required=True, help="the helper's --tee FIFO")
    parser.add_argument("--model", required=True, help="a Vosk model directory")
    parser.add_argument("--rate", type=int, default=8000, help="the FIFO's sample rate")
    parser.add_argument("--pause", type=float, default=0.7, help="silence that ends a line")
    parser.add_argument("--min", type=float, default=0.4, help="speech a line must hold")
    parser.add_argument("--ceiling", type=float, default=20.0, help="longest single line")
    args = parser.parse_args()

    model, Kaldi = load_model(args.model)
    if model is None:
        return 2

    # Resample before segmenting: the model is 16 kHz and 8 kHz fed to it
    # unchanged is read at half speed. The SCO link is 8 kHz, so the doubling is
    # done here, in the same loop: no second process and no pipe in the middle of
    # a live call. Any other rate still goes through ffmpeg.
    direct = None
    if args.rate == 16000 or args.rate * 2 == 16000:
        direct = args.rate
    filt = None
    if direct is None:
        try:
            filt = subprocess.Popen(
                [
                    "ffmpeg", "-nostdin", "-loglevel", "error",
                    "-f", "s16le", "-ar", str(args.rate), "-ac", "1", "-i", "pipe:0",
                    "-f", "s16le", "-ar", "16000", "-ac", "1", "pipe:1",
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
            )
        except Exception as exc:  # noqa: BLE001
            emit({"error": "ffmpeg is needed to resample a %d Hz call: %s" % (args.rate, exc)})
            return 4

    try:
        fifo = os.open(args.fifo, os.O_RDONLY)
    except Exception as exc:  # noqa: BLE001
        emit({"error": "could not open %s: %s" % (args.fifo, exc)})
        return 3

    if filt is not None:
        threading.Thread(target=pump, args=(fifo, filt.stdin), daemon=True).start()
    emit({"event": "ready"})

    seg = Segmenter(model, Kaldi, args.pause, args.min, args.ceiling)
    window_bytes = int(16000 * WINDOW_SECONDS) * 2
    try:
        if direct is not None:
            raw_bytes = int(direct * WINDOW_SECONDS) * 2
            pending = b""
            while True:
                data = os.read(fifo, 8192)
                if not data:
                    break
                pending += data
                while len(pending) >= raw_bytes:
                    raw = pending[:raw_bytes]
                    pending = pending[raw_bytes:]
                    window = raw if direct == 16000 else upsample2(raw)
                    seg.feed(window, rms16(raw))
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
                    seg.feed(window, rms16(window))
    finally:
        seg.finish("end")
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
