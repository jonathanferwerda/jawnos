"""``jawnosctl`` -- the JawnOS desktop command line.

Everything the dashboard does is available headless here, so the same tool
covers a desktop, a server, and a script. In particular ``status`` is a cheap
liveness probe and ``ble`` drives the bridge on either machine.
"""

import argparse
import json
import os
import socket
import sys
import time

from . import __version__, core


# --------------------------------------------------------------------------
# output helpers
# --------------------------------------------------------------------------

def _tick(value):
    return "running" if value else "stopped"


def _human_uptime(seconds):
    try:
        total = int(seconds)
    except (TypeError, ValueError):
        return "unknown"
    days, rem = divmod(total, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return "%dd %dh" % (days, hours)
    if hours:
        return "%dh %dm" % (hours, minutes)
    return "%dm" % minutes


def cmd_status(args):
    settings = core.load_settings()
    info = core.status(settings)
    if args.json:
        print(json.dumps(info, indent=2, sort_keys=True))
        return 0
    print("jawn:       %s   (%s)" % (_tick(info["jawn_up"]), info["jawn_dir"]))
    print("  ui port:  %d" % info["jawn_port"])
    health = info.get("health")
    if health:
        peers = health.get("peers") or []
        print("  version:  %s   (up %s, %d peer%s)" % (
            health.get("version", "?"),
            _human_uptime(health.get("uptime")),
            len(peers), "" if len(peers) == 1 else "s"))
    elif info["jawn_up"]:
        print("  version:  (health did not answer)")
    print("BLE bridge: %s   (127.0.0.1:%d)" % (_tick(info["ble_up"]), core.BRIDGE_PORT))
    print("autostart:  %s" % ("enabled" if info["autostart"] else "disabled"))
    return 0


def cmd_start(args):
    settings = core.load_settings()
    ok, message = core.start_all(settings["jawn_dir"], settings.get("ble_with_jawn", True))
    print(message)
    return 0 if ok else 1


def cmd_stop(args):
    settings = core.load_settings()
    ok, message = core.stop_all(settings["jawn_dir"], settings.get("ble_with_jawn", True))
    print(message)
    return 0 if ok else 1


def cmd_restart(args):
    settings = core.load_settings()
    ok, message = core.restart_all(settings["jawn_dir"], settings.get("ble_with_jawn", True))
    print(message)
    return 0 if ok else 1


def cmd_open(args):
    if core.open_ui(core.load_settings()["jawn_dir"]):
        return 0
    print("could not open a browser")
    return 1


def cmd_log(args):
    path = core.jawn_log_path(core.load_settings()["jawn_dir"])
    if args.follow:
        return _follow(path, args.lines)
    text = core.tail_log(path, args.lines)
    sys.stdout.write(text + ("\n" if text and not text.endswith("\n") else ""))
    return 0


def _follow(path, lines):
    import subprocess
    subprocess.run(["tail", "-n", str(lines), "-f", path])
    return 0


def cmd_dir(args):
    settings = core.load_settings()
    if not args.path:
        print(settings["jawn_dir"])
        return 0
    settings["jawn_dir"] = os.path.expanduser(args.path)
    core.save_settings(settings)
    print("jawn directory set to %s" % settings["jawn_dir"])
    return 0


def cmd_autostart(args):
    if args.action == "status":
        print("enabled" if core.autostart_enabled() else "disabled")
        return 0
    enabled = args.action == "enable"
    core.set_autostart(enabled)
    settings = core.load_settings()
    settings["autostart"] = enabled
    core.save_settings(settings)
    print("autostart %s" % ("enabled" if enabled else "disabled"))
    return 0


def cmd_ticket(args):
    from . import secrets
    if args.action == "import":
        url = args.url
        if url is None:
            url = sys.stdin.read().strip()
        ok, message = secrets.store(url)
        print(message)
        return 0 if ok else 1
    if args.action == "clear":
        secrets.clear()
        print("ticket cleared")
        return 0
    if args.action == "show":
        url = secrets.load()
        print(secrets.mask(url) if url else "no ticket stored")
        return 0 if url else 1
    # status
    print(secrets.describe())
    return 0


# --------------------------------------------------------------------------
# ble passthrough: speak the bridge protocol directly
# --------------------------------------------------------------------------

def _stream(command, stop_events, timeout):
    """Send one command and print every event line until a stop event."""
    try:
        sock = socket.create_connection(("127.0.0.1", core.BRIDGE_PORT), timeout=timeout)
    except OSError:
        print("BLE bridge is not running (start it with: jawnosctl ble start)")
        return 1
    sock.settimeout(timeout)
    try:
        sock.sendall((json.dumps(command) + "\n").encode("utf-8"))
        deadline = time.time() + timeout
        buf = b""
        while time.time() < deadline:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    event = json.loads(line.decode("utf-8"))
                except ValueError:
                    continue
                print(json.dumps(event))
                if event.get("event") in stop_events:
                    return 0
    finally:
        sock.close()
    return 0


def cmd_ble(args):
    action = args.action
    if action in (None, "status"):
        result = _stream({"cmd": "status"}, {"status"}, 5)
        return result
    if action == "start":
        ok, message = core.start_ble()
        print(message)
        return 0 if ok else 1
    if action == "stop":
        ok, message = core.stop_ble()
        print(message)
        return 0 if ok else 1
    if action == "scan":
        return _stream({"cmd": "scan", "seconds": args.seconds}, {"scan_done", "error"}, args.seconds + 15)
    if action == "connect":
        if not args.mac:
            print("ble connect needs a mac")
            return 1
        cmd = {"cmd": "connect", "mac": args.mac}
        for key in ("service", "rx", "tx"):
            value = getattr(args, key)
            if value:
                cmd[key] = value
        if args.mtu:
            cmd["mtu"] = args.mtu
        return _stream(cmd, {"connected", "disconnected", "error"}, 30)
    if action == "disconnect":
        return _stream({"cmd": "disconnect"}, {"disconnected", "status", "error"}, 10)
    if action == "send":
        message = args.message
        if message is None:
            message = sys.stdin.read()
        message = message.rstrip()
        if not message:
            print("ble send needs a message")
            return 1
        return _stream({"cmd": "send", "message": message}, {"sent", "error"}, 30)
    print("unknown ble action: %s" % action)
    return 1


def build_parser():
    parser = argparse.ArgumentParser(prog="jawnosctl", description="Control the JawnOS desktop")
    parser.add_argument("--version", action="version", version="jawnosctl " + __version__)
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("status", help="report jawn and BLE bridge liveness")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_status)

    sub.add_parser("start", help="start jawn (and the BLE bridge)").set_defaults(func=cmd_start)
    sub.add_parser("stop", help="stop the whole jawn tree").set_defaults(func=cmd_stop)
    sub.add_parser("restart", help="restart jawn").set_defaults(func=cmd_restart)
    sub.add_parser("open", help="open the JawnOS UI in a browser").set_defaults(func=cmd_open)

    p = sub.add_parser("log", help="show jawn's log")
    p.add_argument("-n", "--lines", type=int, default=200)
    p.add_argument("-f", "--follow", action="store_true")
    p.set_defaults(func=cmd_log)

    p = sub.add_parser("dir", help="show or set the jawn directory")
    p.add_argument("path", nargs="?")
    p.set_defaults(func=cmd_dir)

    p = sub.add_parser("autostart", help="toggle the BLE bridge at login")
    p.add_argument("action", choices=["enable", "disable", "status"])
    p.set_defaults(func=cmd_autostart)

    p = sub.add_parser("ticket", help="import/clear the stored (encrypted) login ticket")
    p.add_argument("action", choices=["import", "show", "clear", "status"])
    p.add_argument("url", nargs="?", help="the ticket URL (or pipe it on stdin)")
    p.set_defaults(func=cmd_ticket)

    p = sub.add_parser("ble", help="drive the BLE bridge")
    p.add_argument("action", nargs="?", choices=["start", "stop", "status", "scan", "connect", "disconnect", "send"])
    p.add_argument("mac", nargs="?")
    p.add_argument("--seconds", type=int, default=8)
    p.add_argument("--service")
    p.add_argument("--rx")
    p.add_argument("--tx")
    p.add_argument("--mtu", type=int, default=0)
    p.add_argument("--message")
    p.set_defaults(func=cmd_ble, default_ble=True)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 0
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
