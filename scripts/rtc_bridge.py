#!/usr/bin/env python3
"""Carry a screened call's audio to a browser over WebRTC.

While a call is up the gateway owns both directions of it: the caller arrives on
`jawn_call_in`, and whatever is written to `jawn_prompt` is what the caller
hears. This process turns that pair into a WebRTC peer, so the person can take
the call on the device they pressed "Connect me" on.

    rtc_bridge.py --in-cmd 'parec ... jawn_call_in.monitor' \
                  --out-cmd 'pacat ... jawn_prompt'

Signalling is JSON lines on stdin and stdout (the gateway drives both ends, so
there is one socket, not a second port):

    in:  {"cmd":"offer","sdp":"...","type":"offer"}
    in:  {"cmd":"ice","candidate":{...}}
    in:  {"cmd":"quit"}
    out: {"event":"ready"}
    out: {"event":"answer","sdp":"...","type":"answer"}
    out: {"event":"ice","candidate":{...}}
    out: {"event":"state","state":"connected"}
    out: {"event":"error","error":"..."}

The caller's direction is an aiortc audio track fed from `--in-cmd`; the
browser's direction is written to `--out-cmd`. Both commands carry a
`--client-name`, for the same reason the plan's do: WirePlumber remembers the
device an application used last, and an unnamed stream inherits a route.

Echo cancellation is the reason this is WebRTC and not a raw audio socket: the
person's microphone, not the gateway's speaker, is the near end, and the
browser's own canceller is what stops the caller hearing themselves.
"""

import argparse
import array
import asyncio
import json
import subprocess
import sys
import threading

from fractions import Fraction

# The imports are the install check: a venv without aiortc must say so on the
# wire (the gateway reads stdout as JSON), not die with a traceback nobody sees.
try:
    import av
    from aiortc import (
        RTCIceCandidate,
        RTCPeerConnection,
        RTCSessionDescription,
        MediaStreamTrack,
    )
except Exception as _exc:  # noqa: BLE001
    sys.stdout.write(json.dumps({"event": "error",
        "error": "the WebRTC bridge needs aiortc: %s" % _exc}) + "\n")
    sys.stdout.flush()
    raise SystemExit(2)

FRAME_MS = 20


def emit(obj):
    """One JSON line on stdout, whole even if two threads emit at once."""
    with emit.lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()


emit.lock = threading.Lock()


class CallerTrack(MediaStreamTrack):
    """The caller's voice, pulled from the capture command as audio frames."""

    kind = "audio"

    def __init__(self, stdout, rate):
        super().__init__()
        self._out = stdout
        self._rate = rate
        self._samples = int(rate * FRAME_MS / 1000)
        self._need = self._samples * 2
        self._buf = bytearray()
        self._pts = 0

    async def recv(self):
        loop = asyncio.get_running_loop()
        while len(self._buf) < self._need:
            data = await loop.run_in_executor(
                None, self._out.read, self._need - len(self._buf))
            if not data:
                # the call went quiet or the capture ended: send silence rather
                # than starve the encoder, which would make the peer's jitter
                # buffer grow and then jump
                self._buf += b"\x00" * (self._need - len(self._buf))
                break
            self._buf += data
        chunk = bytes(self._buf[: self._need])
        del self._buf[: self._need]
        frame = av.AudioFrame(format="s16", layout="mono", samples=self._samples)
        frame.sample_rate = self._rate
        frame.planes[0].update(chunk)
        frame.pts = self._pts
        frame.time_base = Fraction(1, self._rate)
        self._pts += self._samples
        return frame


def to_mono(frame):
    """The browser may send stereo; the prompt sink is mono."""
    raw = bytes(frame.planes[0])
    channels = len(frame.layout.channels)
    need = frame.samples * 2 * channels
    raw = raw[:need]
    if channels <= 1:
        return raw
    samples = array.array("h")
    samples.frombytes(raw)
    out = array.array("h", bytes(2 * frame.samples))
    for i in range(frame.samples):
        total = 0
        for c in range(channels):
            total += samples[i * channels + c]
        out[i] = int(total / channels)
    return out.tobytes()


class Bridge:
    def __init__(self, in_cmd, out_cmd, rate):
        self.in_cmd = in_cmd
        self.out_cmd = out_cmd
        self.rate = rate
        self.capture = None
        self.playback = None
        self.pc = None
        self.write_lock = threading.Lock()

    def start(self):
        self.capture = subprocess.Popen(
            self.in_cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.playback = subprocess.Popen(
            self.out_cmd, shell=True, stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
        emit({"event": "ready", "rate": self.rate})

    async def offer(self, sdp, kind):
        await self.close_peer()
        pc = RTCPeerConnection()
        self.pc = pc

        @pc.on("icecandidate")
        def on_ice(candidate):
            if candidate is None:
                return
            emit({"event": "ice", "candidate": {
                "candidate": candidate.candidate,
                "sdpMid": candidate.sdpMid,
                "sdpMLineIndex": candidate.sdpMLineIndex,
            }})

        @pc.on("connectionstatechange")
        def on_state():
            emit({"event": "state", "state": pc.connectionState})

        @pc.on("track")
        def on_track(track):
            if track.kind == "audio":
                asyncio.ensure_future(self.consume(track))

        pc.addTrack(CallerTrack(self.capture.stdout, self.rate))
        await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type=kind))
        answer = await pc.createAnswer()
        await pc.setLocalDescription(answer)
        emit({"event": "answer", "sdp": pc.localDescription.sdp,
              "type": pc.localDescription.type})

    async def consume(self, track):
        # One writer at a time: two tracks (a renegotiation) must not interleave.
        while True:
            try:
                frame = await track.recv()
            except Exception:
                return
            data = to_mono(frame)
            try:
                with self.write_lock:
                    self.playback.stdin.write(data)
                    self.playback.stdin.flush()
            except Exception:
                return

    async def ice(self, candidate):
        if self.pc is None:
            return
        try:
            await self.pc.addIceCandidate(RTCIceCandidate(
                candidate.get("candidate", ""),
                sdpMid=candidate.get("sdpMid"),
                sdpMLineIndex=candidate.get("sdpMLineIndex"),
            ))
        except Exception as exc:  # noqa: BLE001
            emit({"event": "error", "error": "ice: %s" % exc})

    async def close_peer(self):
        pc = self.pc
        self.pc = None
        if pc is not None:
            try:
                await pc.close()
            except Exception:
                pass

    async def close(self):
        await self.close_peer()
        for proc in (self.capture, self.playback):
            if proc is None:
                continue
            try:
                proc.terminate()
            except Exception:
                pass
        for proc in (self.capture, self.playback):
            if proc is None:
                continue
            try:
                proc.wait(timeout=2)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass


async def main():
    parser = argparse.ArgumentParser(description="WebRTC bridge for a screened call")
    parser.add_argument("--in-cmd", required=True, help="the caller's capture command")
    parser.add_argument("--out-cmd", required=True, help="the caller's playback command")
    parser.add_argument("--rate", type=int, default=48000)
    args = parser.parse_args()

    bridge = Bridge(args.in_cmd, args.out_cmd, args.rate)
    bridge.start()

    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()

    def read_stdin():
        for line in sys.stdin:
            line = line.strip()
            if line:
                loop.call_soon_threadsafe(queue.put_nowait, line)
        loop.call_soon_threadsafe(queue.put_nowait, None)

    threading.Thread(target=read_stdin, daemon=True).start()

    while True:
        line = await queue.get()
        if line is None:
            break
        try:
            message = json.loads(line)
        except Exception:
            continue
        command = message.get("cmd", "")
        if command == "offer":
            try:
                await bridge.offer(message.get("sdp", ""), message.get("type", "offer"))
            except Exception as exc:  # noqa: BLE001
                emit({"event": "error", "error": "offer: %s" % exc})
        elif command == "ice":
            await bridge.ice(message.get("candidate") or {})
        elif command == "quit":
            break

    await bridge.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        sys.exit(0)
