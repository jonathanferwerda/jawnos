#!/usr/bin/env python3
"""Vosk speech-to-text, for the house.

Vosk is the free, offline recogniser: a small model, a few dozen megabytes of
RAM, and a word out in well under a second on a laptop. The Perl side
(subs::vosk_transcribe) runs this with the interpreter the installer made at
~/.local/share/jawnos/vosk/venv, so nothing here needs a system-wide pip.

Three ways in, all writing one JSON object per line to stdout:

    # any container ffmpeg reads (webm, wav, ogg), the whole clip at once
    vosk_transcribe.py --model DIR < clip.webm
    -> {"text": "my name is john"}

    # raw 16 kHz mono s16le, already decoded
    vosk_transcribe.py --model DIR --raw < clip.pcm
    -> {"text": "my name is john"}

    # a live stream of the same raw PCM; partials as they are recognised and
    # the final line when the stream ends. This is what the screening transcript
    # listens to, because a partial is the whole point of it.
    vosk_transcribe.py --model DIR --raw --stream < jawn_call_in.pcm
    -> {"partial": "my name"}
    -> {"text": "my name is john", "final": true}

An error is one line, {"error": "..."}, and a non-zero exit; the caller treats
that as "no transcript" and falls back to whisper.cpp. Never write diagnostics
to stdout: it is the wire.
"""

import argparse
import json
import subprocess
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def load_vosk():
    try:
        from vosk import Model, KaldiRecognizer, SetLogLevel
    except Exception as exc:  # noqa: BLE001 - any import failure is the same answer
        emit({"error": "vosk is not installed: %s" % exc})
        return None
    SetLogLevel(-1)
    return Model, KaldiRecognizer


def recogniser(Model, KaldiRecognizer, model_dir):
    try:
        model = Model(model_dir)
    except Exception as exc:  # noqa: BLE001
        emit({"error": "vosk model %s: %s" % (model_dir, exc)})
        return None
    rec = KaldiRecognizer(model, 16000)
    try:
        rec.SetWords(True)
    except Exception:
        pass
    return rec


def stream(rec):
    """Feed a raw 16 kHz mono s16le stream, narrating it as it goes."""
    last_partial = ""
    while True:
        data = sys.stdin.buffer.read(4096)
        if not data:
            break
        if rec.AcceptWaveform(data):
            text = json.loads(rec.Result()).get("text", "").strip()
            if text:
                emit({"text": text, "final": True})
                last_partial = ""
        else:
            partial = json.loads(rec.PartialResult()).get("partial", "").strip()
            # a partial that has not grown is noise, not news
            if partial and partial != last_partial and not partial.startswith(last_partial):
                emit({"partial": partial})
                last_partial = partial
    text = json.loads(rec.FinalResult()).get("text", "").strip()
    if text:
        emit({"text": text, "final": True})


def whole(rec, path, raw):
    """Feed one clip and print its transcript."""
    if path:
        source = open(path, "rb")
        proc = None
        feed = source
    else:
        feed = sys.stdin.buffer
        proc = None
    if not raw:
        cmd = ["ffmpeg", "-nostdin", "-loglevel", "error"]
        cmd += ["-i", path] if path else ["-i", "-"]
        cmd += ["-f", "s16le", "-ac", "1", "-ar", "16000", "-"]
        proc = subprocess.Popen(cmd, stdin=None if path else feed, stdout=subprocess.PIPE)
        feed = proc.stdout
    try:
        while True:
            data = feed.read(4096)
            if not data:
                break
            rec.AcceptWaveform(data)
        if proc is not None:
            proc.wait()
    finally:
        if path:
            try:
                source.close()
            except Exception:
                pass
    text = json.loads(rec.FinalResult()).get("text", "").strip()
    emit({"text": text})


def main():
    parser = argparse.ArgumentParser(description="Vosk transcription for JawnOS")
    parser.add_argument("--model", required=True, help="a Vosk model directory")
    parser.add_argument("--lang", default="", help="the language asked for (recorded, not selected)")
    parser.add_argument("--raw", action="store_true", help="stdin is 16 kHz mono s16le")
    parser.add_argument("--stream", action="store_true", help="keep reading until stdin closes")
    parser.add_argument("--file", default="", help="read this file instead of stdin")
    args = parser.parse_args()

    loaded = load_vosk()
    if not loaded:
        return 2
    Model, KaldiRecognizer = loaded
    rec = recogniser(Model, KaldiRecognizer, args.model)
    if rec is None:
        return 3

    if args.stream and not args.raw:
        emit({"error": "--stream needs --raw (16 kHz mono s16le)"})
        return 4

    if args.stream:
        stream(rec)
    else:
        whole(rec, args.file, args.raw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
