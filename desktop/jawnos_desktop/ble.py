"""The JawnOS BLE bridge for Linux.

This is the Linux twin of ``JawnBleService.java`` in the JawnOS Android API app.
It is a real Bluetooth LE *central* (built on BlueZ over D-Bus) that links to
NUS peripherals -- watches and boards -- and relays newline-delimited JSON to
and from the rest of jawn.

The wire protocol on the loopback control socket is backward-compatible with
the Android daemon and the v1 Linux bridge, so ``scripts/jawn-bt`` and jawn's
own Perl listener (``ble_listener_start``) work unchanged.  Version 2 adds up
to four concurrent links: every link-scoped event carries ``mac``, ``status``
carries a ``links`` array, and ``send``/``disconnect`` may target one MAC.

    listen on 127.0.0.1:45999

    commands (one JSON object per line, from any client):
        {"cmd":"scan","seconds":8}
        {"cmd":"connect","mac":"..","service":"..","rx":"..","tx":"..",
         "mtu":512,"compress":true}
        {"cmd":"send","message":".."}                  # primary link
        {"cmd":"send","mac":"..","message":"..","id":N}
        {"cmd":"disconnect"} | {"cmd":"disconnect","mac":".."}
        {"cmd":"disconnect","all":true} | {"cmd":"status"} | {"cmd":"shutdown"}

    events (one JSON object per line, to every client):
        {"event":"status","protocol":2,"connected":bool,"mac":..|null,
         "mtu":n,"count":n,"links":[..]}
        {"event":"scan","mac":..,"name":..|null,"rssi":n,"uuids":[..]}
        {"event":"scan_done"}
        {"event":"error","message":"..","mac":..,"code":".."}
        {"event":"connected","mac":..,"mtu":n,"service":..,"rx":..,"tx":..}
        {"event":"disconnected","mac":..,"status":n,
         "reason":"peer|local|timeout","next_retry_ms":n}
        {"event":"message","mac":..,"data":".."}
        {"event":"sent","mac":..,"id":N}

Payload framing matches the Android daemon and the watch firmware exactly: a
payload too big for one write is split as ``<i>/<n>:`` + chunk (0-based), and the
watch reassembles it (see jw.ino::ble_frame_ingest).  Reassembly in this
direction is per link and byte-safe: parts are kept as bytes and decoded once
when the last part arrives.

All Bluetooth work runs on the GLib main loop; the only threads are the socket
accept loop and one reader per client, which hand commands to the loop.  The
D-Bus connect is asynchronous, so a slow or absent device never freezes the
daemon.  Multi-part writes are paced by a per-link GLib pump instead of a
blocking ``time.sleep`` loop, so a large send on one link cannot stall another.
"""

import argparse
import json
import os
import re
import socket
import sys
import threading
import time
import zlib
from collections import deque

from .core import BRIDGE_PORT, ble_pid_path, config_dir

try:
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib
    HAVE_BLUEZ = True
except Exception:  # pragma: no cover - reported to the user at runtime
    HAVE_BLUEZ = False

BLUEZ = "org.bluez"
OM_IFACE = "org.freedesktop.DBus.ObjectManager"
ADAPTER_IFACE = "org.bluez.Adapter1"
DEVICE_IFACE = "org.bluez.Device1"
GATT_SERVICE_IFACE = "org.bluez.GattService1"
GATT_CHAR_IFACE = "org.bluez.GattCharacteristic1"
# A PropertiesChanged signal is emitted on org.freedesktop.DBus.Properties,
# NOT on the interface whose property changed. A signal match rule keyed on the
# concrete iface (org.bluez.Device1 / org.bluez.GattCharacteristic1) therefore
# never fires -- which silently dropped every watch -> daemon notification
# (buttons, state_request, steps) until this was pinned to the right iface. The
# handler still receives the *changed object's* iface as its first argument, so
# nothing else changes.
DBUS_PROPS = "org.freedesktop.DBus.Properties"

# The JawnOS watches and boards all speak the Nordic UART Service. These are
# the fallback when a connect names no characteristics of its own.
NUS_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
NUS_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

DEFAULT_MTU = 23          # ATT default, as in the Android daemon
CONNECT_TIMEOUT_MS = 20000
RECONNECT_START = 3.0     # seconds; doubles to RECONNECT_MAX
RECONNECT_MAX = 30.0
# Only a link that stood this long is a real link. A drop sooner than this is a
# flap (the watch reboots, or its radio sleeps): the backoff keeps doubling
# instead of resetting, so a connect-then-drop loop cannot retry every 3 s
# forever and cook the machine that hosts the bridge.
STABLE_SECONDS = 30.0

MAX_LINKS = 4
CONNECT_AFTER_DISCOVERY_MS = 400
# A multi-part write yields to the GLib loop between parts. The old code slept
# 15 ms inside the write, which blocked every other link for the duration of a
# large room push.
TX_PART_INTERVAL_MS = 15
# A send aimed at a link that is not up yet is queued, but only briefly: the
# caller (usually the tree's retry tick) gets a clear "not connected" if the
# link never comes up.
SEND_QUEUE_TTL = 20.0
SEND_QUEUE_MAX = 4096

# Large daemon -> watch payloads (the ~25 KB room push) are zlib-compressed before
# they go over the air; BLE is the slow part and the JSON deflates ~4x. A leading
# 0x1e byte marks a compressed body (no JSON message starts with it); the watch
# inflates it with the ESP32 ROM's miniz. Small messages ride uncompressed.
# Compression is per link (connect's "compress" flag).
TX_ZLIB_MIN = 512
TX_ZLIB_MARK = 0x1e

# The watch frames a payload that will not fit one notification the same way the
# daemon frames a write: "<i>/<n>:" + chunk, 0-based. A notification with no such
# prefix is a whole message. Only the voice clip uses this direction today.
FRAME_RE = re.compile(rb"^(\d+)/(\d+):")
RX_GAP_SECONDS = 5.0      # a pause this long means a new message, not a lost part
RX_MAX_PARTS = 4096       # a runaway total cannot grow the buffer without bound


def frame_payload(data, mtu):
    """Split *data* (bytes) into the daemon's framed chunks.

    Framing matches the Android daemon and the watch firmware
    (``<i>/<n>:`` + chunk). The sizes are pinned to the ATT limit, not the
    Android long-write maths: the watch only accepts **Write Without
    Response**, which cannot be fragmented, so one framed part must fit in
    ``mtu - 3`` bytes. 12 covers the longest ``"<i>/<n>:"`` prefix."""
    max_part = max(20, mtu - 3)
    body = max(1, max_part - 12)
    total = 1 if len(data) == 0 else (len(data) + body - 1) // body
    parts = []
    for i in range(total):
        chunk = data[i * body:(i + 1) * body]
        parts.append(("%d/%d:" % (i, total)).encode("ascii") + chunk)
    return parts


def _mac(value):
    """One radio address, one spelling.

    BlueZ reports ``AA:BB:CC:DD:EE:FF``; a devices row (and older targets) may
    carry the same address without the colons. Keying the link map on the raw
    string opened a second, phantom link for the same peripheral - one that can
    never connect, because find_device compares against BlueZ's colon form.
    Canonicalize to the colon form every daemon event and command uses.
    """
    text = str(value or "").strip().upper().replace(":", "").replace("-", "")
    if len(text) == 12 and all(c in "0123456789ABCDEF" for c in text):
        return ":".join(text[i:i + 2] for i in range(0, 12, 2))
    return str(value or "").strip().upper()


def _as_bool(value, default=True):
    """Interpret the several ways JSON/perl callers spell a boolean."""
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value).strip().lower()
    if text in ("0", "false", "no", "off", ""):
        return False
    return True


def _target_store():
    return os.path.join(config_dir(), "ble.json")


def bridge_name():
    """The name the watch shows for this machine.

    Prefer JawnOS's own name for the computer (config.json's "name", e.g.
    "Laptop") -- that is what the user recognises across their devices -- and
    fall back to the hostname if the tree is not readable."""
    try:
        from . import core
        config = core.read_app_config(core.load_settings()["jawn_dir"])
        name = str(config.get("name") or "").strip()
        if name:
            return name
    except Exception:
        pass
    return socket.gethostname()


def _normalise_target(mac, raw):
    """A stored/live target with every field present and sane."""
    raw = raw if isinstance(raw, dict) else {}
    mac = _mac(raw.get("mac") or mac)
    try:
        mtu = int(raw.get("mtu") or 0)
    except (TypeError, ValueError):
        mtu = 0
    try:
        updated = float(raw.get("updated") or 0)
    except (TypeError, ValueError):
        updated = 0.0
    return {
        "mac": mac,
        "service": str(raw.get("service") or NUS_SERVICE),
        "rx": str(raw.get("rx") or NUS_RX),
        "tx": str(raw.get("tx") or NUS_TX),
        "mtu": mtu or 512,
        "compress": _as_bool(raw.get("compress"), True),
        "updated": updated if updated > 0 else time.time(),
    }


def load_targets():
    """Return {MAC: target}, newest first-ish, at most MAX_LINKS entries.

    The v2 file is ``{"version":2,"targets":{MAC:target}}``. A v1 file was the
    single flat target ({"mac":..,"service":..}). It is migrated on load."""
    try:
        with open(_target_store(), "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return {}

    targets = {}
    migrated = False
    if isinstance(raw, dict):
        if isinstance(raw.get("targets"), dict):
            for mac, target in raw["targets"].items():
                key = _mac(mac)
                if key:
                    targets[key] = _normalise_target(key, target)
        elif raw.get("mac"):
            key = _mac(raw.get("mac"))
            targets[key] = _normalise_target(key, raw)
            migrated = True
    else:
        migrated = True

    if len(targets) > MAX_LINKS:
        targets = dict(sorted(targets.items(),
                              key=lambda kv: kv[1].get("updated", 0),
                              reverse=True)[:MAX_LINKS])
        migrated = True
    if migrated and targets:
        save_targets(targets)
    return targets


def save_targets(targets):
    """Persist at most the four newest targets."""
    items = [t for t in targets.values() if t.get("mac")]
    items.sort(key=lambda t: t.get("updated", 0), reverse=True)
    payload = {
        "version": 2,
        "targets": {t["mac"]: t for t in items[:MAX_LINKS]},
    }
    try:
        os.makedirs(config_dir(), exist_ok=True)
        with open(_target_store(), "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
    except OSError:
        pass


# Kept for compatibility with older callers/imports: the flat, single-target
# shape is now just the newest entry.
def load_target():
    targets = load_targets()
    if not targets:
        return {}
    return max(targets.values(), key=lambda t: t.get("updated", 0))


def save_target(target):
    mac = _mac((target or {}).get("mac"))
    if not mac:
        return
    targets = load_targets()
    targets[mac] = _normalise_target(mac, target)
    save_targets(targets)


class Link(object):
    """Everything that belongs to one BLE link.

    The bridge used to keep all of this on itself. With up to four links each
    piece of connection state, each signal receiver, each backoff, and each RX
    reassembly buffer must be independent: a drop on one link must not touch
    another's chars, timers, or half-received message.
    """

    def __init__(self, target, auto_reconnect=False):
        self.target = dict(target)
        self.mac = target["mac"]
        self.device_path = None
        self.write_char = None
        self.notify_char = None
        try:
            self.mtu = int(target.get("mtu") or DEFAULT_MTU)
        except (TypeError, ValueError):
            self.mtu = DEFAULT_MTU

        self.auto_reconnect = bool(auto_reconnect)
        self.reconnect_delay = RECONNECT_START
        self.next_attempt = 0.0
        self.attempt = 0
        self.connecting = False
        self.connecting_at = 0.0
        self.connected_at = 0.0
        self.pending_connect = False
        self.polling = False
        self.state = "idle"
        self.since = time.time()

        self._char_signal = None
        self._device_signal = None

        # watch -> daemon reassembly, per link (a framed voice clip arrives in
        # parts). Parts stay bytes until the whole message is present.
        self._rx_parts = None
        self._rx_total = 0
        self._rx_at = 0.0

        # daemon -> watch queue, per link, pumped on the GLib loop.
        self.tx_queue = deque()
        self.tx_active = False
        self.tx_parts = []
        self.tx_index = 0
        self.tx_item = None

    def connected(self):
        return bool(self.write_char and self.device_path)

    def set_state(self, state):
        if state != self.state:
            self.state = state
            self.since = time.time()


class Bridge(object):
    def __init__(self, port=BRIDGE_PORT, log=None):
        self.port = port
        self.log = log or (lambda *a: None)
        self.running = True
        self.server = None
        self.clients = set()
        self.clients_lock = threading.Lock()

        # the last error emitted, so a link that is down does not answer every
        # attempted send with the same line (the tree retries on its own tick)
        self._last_error_key = None
        self._last_error_at = 0.0
        self._error_suppressed = 0

        self.scanning = False
        # address -> (name, uuids): the record last emitted, so a scan reports a
        # device once and then only when its name or service uuids grow.
        self.scan_seen = {}

        self.bus = None
        self.loop = None
        self.om = None
        # MAC -> Link. Insertion order is the order connects were accepted.
        self.links = {}
        self.host_name = bridge_name()
        self.discovery_owner = None

    # ---- logging / emit ----

    def info(self, *parts):
        self.log(" ".join(str(p) for p in parts))

    def emit(self, obj):
        line = (json.dumps(obj) + "\n").encode("utf-8")
        with self.clients_lock:
            dead = []
            for sock in self.clients:
                try:
                    sock.sendall(line)
                except OSError:
                    dead.append(sock)
            for sock in dead:
                self.clients.discard(sock)
                try:
                    sock.close()
                except OSError:
                    pass

    def emit_error(self, message, mac=None, code=None):
        # a send to a missing link answers the same way every time; repeat the
        # identical error at most once every 30s, and say how many were folded.
        # The MAC (and code) are part of the key so one dead link cannot hide
        # another link's error.
        mac = _mac(mac) if mac else None
        key = (message, mac, code)
        now = time.time()
        if key == self._last_error_key and (now - self._last_error_at) < 30.0:
            self._error_suppressed += 1
            return
        if self._error_suppressed and self._last_error_key:
            self.info("error:", "%s (+%d more)" % (self._last_error_key[0],
                                                   self._error_suppressed))
            self._error_suppressed = 0
        self._last_error_key = key
        self._last_error_at = now
        self.info("error:", message, mac or "", code or "")
        event = {"event": "error", "message": message}
        if mac:
            event["mac"] = mac
        if code:
            event["code"] = code
        self.emit(event)

    def _primary(self):
        """The most recently connected link, or None."""
        connected = [link for link in self.links.values() if link.connected()]
        if not connected:
            return None
        return max(connected, key=lambda link: link.connected_at)

    def connected(self):
        return self._primary() is not None

    # ---- BlueZ setup ----

    def start_bluez(self):
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        try:
            dbus.mainloop.glib.threads_init()
        except Exception:
            pass
        self.bus = dbus.SystemBus()
        self.om = dbus.Interface(self.bus.get_object(BLUEZ, "/"), OM_IFACE)
        self.bus.add_signal_receiver(
            self._on_interfaces_added, bus_name=BLUEZ,
            dbus_interface=OM_IFACE, signal_name="InterfacesAdded")
        self.info("bluez ready")

    def _managed(self):
        try:
            return self.om.GetManagedObjects()
        except dbus.exceptions.DBusException as exc:
            self.info("GetManagedObjects failed:", exc)
            return {}

    def _adapter_path(self):
        for path, ifaces in self._managed().items():
            if ADAPTER_IFACE in ifaces:
                return str(path)
        return None

    @staticmethod
    def _iface(bus, path, name):
        return dbus.Interface(bus.get_object(BLUEZ, path), name)

    def _prop(self, path, name):
        # Properties live on org.freedesktop.DBus.Properties, NOT on the
        # org.bluez.Device1 interface: calling Device1.Get raises "Method Get
        # ... doesn't exist", which silently stalled the service-resolution
        # wait for its full 10 s timeout -- long enough for the watch to sleep
        # and drop the link.
        props = dbus.Interface(self.bus.get_object(BLUEZ, path), 'org.freedesktop.DBus.Properties')
        return props.Get(DEVICE_IFACE, name)

    def _bluetooth_ready(self):
        adapter = self._adapter_path()
        if adapter is None:
            self.emit_error("no bluetooth adapter (is bluetoothd running?)")
            return None
        props = self._managed().get(dbus.ObjectPath(adapter), {}).get(ADAPTER_IFACE, {})
        if not props.get("Powered"):
            self.emit_error("bluetooth adapter is powered off")
            return None
        return adapter

    # ---- discovery (shared by scan and every connect) ----
    #
    # BlueZ discovery is adapter-wide: there can only be one StartDiscovery, so
    # the bridge keeps a single owner ("scan" or "connect") for all links.

    def _start_discovery(self, owner):
        if self.discovery_owner is not None:
            return
        adapter = self._adapter_path()
        if adapter is None:
            return
        try:
            self._iface(self.bus, adapter, ADAPTER_IFACE).StartDiscovery()
            self.discovery_owner = owner
        except dbus.exceptions.DBusException as exc:
            if "InProgress" in str(exc):
                self.discovery_owner = owner
            else:
                self.info("start discovery failed:", exc)

    def _stop_discovery(self, owner):
        if self.discovery_owner != owner:
            return
        self.discovery_owner = None
        adapter = self._adapter_path()
        if adapter is None:
            return
        try:
            self._iface(self.bus, adapter, ADAPTER_IFACE).StopDiscovery()
        except dbus.exceptions.DBusException:
            pass

    def _any_waiting(self, except_link=None):
        for link in self.links.values():
            if link is except_link:
                continue
            if link.connected() or link.connecting:
                continue
            if link.pending_connect or link.auto_reconnect:
                return True
        return False

    # ---- scan ----

    def _on_interfaces_added(self, path, interfaces):
        if self.scanning and DEVICE_IFACE in interfaces:
            self._emit_scan(interfaces[DEVICE_IFACE])

    def _emit_scan(self, props):
        address = str(props.get("Address", "")).upper()
        if not address:
            return
        name = props.get("Alias") or props.get("Name")
        # The service uuids a device advertises: a JawnOS board puts the Nordic
        # UART service in its advertising packet, so this is how the tree tells
        # one of its own from the rest of the room, without connecting.
        uuids = sorted(str(u).lower() for u in (props.get("UUIDs") or []))
        record = (str(name) if name else None, tuple(uuids))
        # Report on first sight, and again only if the name or uuids grow: a device
        # seen from its advertising packet alone may carry neither yet, and BlueZ
        # fills them in from the scan response a moment later.
        if self.scan_seen.get(address) == record:
            return
        self.scan_seen[address] = record
        self.emit({
            "event": "scan",
            "mac": address,
            "name": str(name) if name else None,
            "rssi": int(props.get("RSSI", 0) or 0),
            "uuids": list(uuids),
        })

    def _start_scan(self, seconds):
        if self.scanning:
            return
        if self._bluetooth_ready() is None:
            return
        self.scanning = True
        self.scan_seen = {}
        # Devices BlueZ already knows count too: discovery reports only new ones.
        for _path, ifaces in self._managed().items():
            if DEVICE_IFACE in ifaces:
                self._emit_scan(ifaces[DEVICE_IFACE])
        self._start_discovery("scan")
        GLib.timeout_add_seconds(max(1, seconds), self._stop_scan)

    def _stop_scan(self):
        if not self.scanning:
            return False
        self.scanning = False
        self._stop_discovery("scan")
        if self._any_waiting():
            # a pending connect still needs discovery; take it back over
            self._keep_discovering()
        self.info("scan finished,", len(self.scan_seen), "device(s)")
        self.emit({"event": "scan_done"})
        return False

    # ---- connect ----

    def _devices(self):
        out = {}
        for path, ifaces in self._managed().items():
            if DEVICE_IFACE in ifaces:
                out[str(path)] = ifaces[DEVICE_IFACE]
        return out

    def find_device(self, mac):
        want = _mac(mac)
        for path, props in self._devices().items():
            if str(props.get("Address", "")).upper() == want:
                return path
        return None

    def _remember(self, link):
        link.target["updated"] = time.time()
        targets = load_targets()
        targets[link.mac] = dict(link.target)
        save_targets(targets)

    def _admit_link(self):
        """Make room for one more link, or say no.

        An idle (explicitly disconnected) link is the cheapest thing to forget;
        a live link is never evicted. Four live links is the cap."""
        if len(self.links) < MAX_LINKS:
            return True
        idle = [link for link in self.links.values()
                if link.state == "idle" and not link.connected()
                and not link.connecting and not link.pending_connect]
        if not idle:
            return False
        victim = min(idle, key=lambda link: link.since)
        self._fail_pending(victim)
        self.links.pop(victim.mac, None)
        return True

    def connect(self, mac, service=None, rx=None, tx=None, mtu=0, compress=None):
        mac = _mac(mac)
        if not mac:
            self.emit_error("connect: mac required")
            return
        # Omitted characteristic UUIDs default to NUS (the v2 contract). The
        # stored target is used by startup restore and by reconnect, which pass
        # its values explicitly, so a custom target still survives a restart.
        link = self.links.get(mac)
        try:
            mtu = int(mtu or (link.target.get("mtu") if link else 0) or 0)
        except (TypeError, ValueError):
            mtu = 0
        target = {
            "mac": mac,
            "service": str(service or NUS_SERVICE),
            "rx": str(rx or NUS_RX),
            "tx": str(tx or NUS_TX),
            "mtu": mtu or 512,
            "compress": True if compress is None else _as_bool(compress, True),
            "updated": time.time(),
        }
        conn_keys = ("service", "rx", "tx", "mtu")

        if link is None:
            if not self._admit_link():
                self.emit_error("too many links (max %d)" % MAX_LINKS,
                                mac=mac, code="too_many_links")
                return
            link = Link(target, auto_reconnect=True)
            self.links[mac] = link
            self._remember(link)
            link.reconnect_delay = RECONNECT_START
            link.attempt = 0
            self._begin_connect(link)
            return

        same_connection = all(link.target.get(k) == target[k] for k in conn_keys)
        if same_connection:
            # A compression-flag change is per-link and does not disturb the
            # connection; apply it and leave an active link alone.
            if link.target.get("compress") != target["compress"]:
                link.target["compress"] = target["compress"]
                link.target["updated"] = target["updated"]
                self._remember(link)
            if link.connected() or link.pending_connect or link.connecting:
                self.status()
                return
            # Same target, idle: act like a connect request.
            link.auto_reconnect = True
            link.reconnect_delay = RECONNECT_START
            link.attempt = 0
            self._remember(link)
            self._begin_connect(link)
            return

        # A different target for this MAC reconnects only this link.
        link.target = target
        link.mtu = target["mtu"]
        self._remember(link)
        link.auto_reconnect = True
        link.reconnect_delay = RECONNECT_START
        link.attempt = 0
        self.close_link(link, emit=True, reason="local", schedule=False)
        self._begin_connect(link)

    def _begin_connect(self, link):
        if not self.running or self.links.get(link.mac) is not link:
            return
        # pending_connect covers the whole flow (discovery then connect), so a
        # second queued connect -- our explicit one plus the startup
        # auto-connect, say -- does not spawn a rival discovery timer.
        if link.connecting or link.connected() or link.pending_connect:
            return
        if not link.target.get("mac"):
            return
        if self._bluetooth_ready() is None:
            self._schedule_reconnect(link)
            return
        link.pending_connect = True
        link.next_attempt = 0.0
        link.set_state("connecting")
        path = self.find_device(link.mac)
        if path:
            self._connect_device(link, path)
            return
        # Not known yet: discover until it shows up, then connect. Non-blocking
        # so the daemon stays responsive (and stoppable) the whole time.
        self.info("waiting for", link.mac, "to advertise")
        # Do not start (or restart) discovery while another link's Connect()
        # is in flight; its poll re-arms discovery as soon as that settles.
        if not any(other.connecting for other in self.links.values() if other is not link):
            self._start_discovery("connect")
        if not link.polling:
            link.polling = True
            GLib.timeout_add(500, self._poll_for_device, link)

    def _poll_for_device(self, link):
        if self.links.get(link.mac) is not link:
            link.polling = False
            return False
        if not (link.pending_connect or link.auto_reconnect) or link.connected() or link.connecting:
            link.polling = False
            if not self._any_waiting(link):
                self._stop_discovery("connect")
            return False
        path = self.find_device(link.mac)
        if path:
            # Let bluetoothd actually stop scanning before initiating the link:
            # on some controllers (Intel) a connect issued while the scanner is
            # still winding down aborts with le-connection-abort-by-local.
            # Another waiting link re-arms discovery from its own poll once no
            # Connect() is in flight (see _keep_discovering).
            link.polling = False
            self._stop_discovery("connect")
            GLib.timeout_add(CONNECT_AFTER_DISCOVERY_MS, self._connect_device, link, path)
            return False
        # BlueZ's StartDiscovery lapses on its own (~30 s) and nothing else
        # re-arms it, so keep it alive for every still-waiting link.
        self._keep_discovering()
        return True

    def _keep_discovering(self):
        if not self.running:
            return
        # Do not fight a Connect() in flight: the controller may abort the
        # connection if a scan is restarted at the same time.
        if any(link.connecting for link in self.links.values()):
            return
        if self.discovery_owner not in (None, "connect"):
            return   # a scan owns discovery; do not fight it
        adapter = self._adapter_path()
        if adapter is None:
            return
        props = self._managed().get(dbus.ObjectPath(adapter), {}).get(ADAPTER_IFACE, {})
        if props.get("Discovering"):
            self.discovery_owner = "connect"
            return
        self.discovery_owner = None
        self._start_discovery("connect")

    def _connect_device(self, link, path):
        if self.links.get(link.mac) is not link:
            return
        if link.connecting or link.connected():
            return
        link.pending_connect = True
        link.connecting = True
        link.connecting_at = time.time()
        link.set_state("connecting")
        try:
            device = self._iface(self.bus, path, DEVICE_IFACE)
            device.Connect(
                reply_handler=lambda: self._after_connect(link, path),
                error_handler=lambda exc: self._connect_failed(link, exc),
                timeout=CONNECT_TIMEOUT_MS)
        except dbus.exceptions.DBusException as exc:
            self._connect_failed(link, exc)

    def _connect_failed(self, link, exc):
        if self.links.get(link.mac) is not link:
            return
        # A disconnect (or a target replacement) may have cleared the attempt
        # while Connect() was still in flight; its late failure is stale.
        if not link.connecting and not link.pending_connect:
            return
        self.emit_error("connect failed: %s" % exc, mac=link.mac)
        self.close_link(link, emit=True, reason="timeout", schedule=True)

    def _after_connect(self, link, path):
        if self.links.get(link.mac) is not link:
            try:
                self._iface(self.bus, path, DEVICE_IFACE).Disconnect()
            except dbus.exceptions.DBusException:
                pass
            return
        # The user may have disconnected while Connect() was in flight. The
        # link no longer wants this path, so undo the connection instead of
        # leaving an orphaned BlueZ device behind.
        if not link.connecting and not link.pending_connect:
            try:
                self._iface(self.bus, path, DEVICE_IFACE).Disconnect()
            except dbus.exceptions.DBusException:
                pass
            return
        link.device_path = path
        # the backoff resets only once the link has proved itself (see
        # close_link / STABLE_SECONDS): resetting it here is what made a link
        # that connects and immediately drops retry every 3 s, endlessly
        self._drop_signal(link, "_device_signal")
        link._device_signal = self.bus.add_signal_receiver(
            lambda *a, **kw: self._on_device_props(link, *a, **kw),
            bus_name=BLUEZ, dbus_interface=DBUS_PROPS,
            signal_name="PropertiesChanged", path=path)
        GLib.timeout_add(200, self._wait_services, link, path, time.time() + 10.0)

    def _wait_services(self, link, path, deadline):
        if self.links.get(link.mac) is not link or link.device_path != path:
            return False
        try:
            resolved = bool(self._prop(path, "ServicesResolved"))
        except dbus.exceptions.DBusException:
            resolved = False
        if resolved or time.time() > deadline:
            self._finish_connect(link, path)
            return False
        return True

    def _finish_connect(self, link, path):
        if self.links.get(link.mac) is not link or link.device_path != path:
            return
        # Connect() returning is not proof the link survived; check before
        # trusting it, or a drop lands as a phantom "connected" state.
        try:
            if not self._prop(path, "Connected"):
                self.close_link(link, emit=True, reason="peer", schedule=True)
                return
        except dbus.exceptions.DBusException:
            pass
        try:
            write_char, notify_char = self._resolve_chars(
                path, link.target.get("service"), link.target.get("rx"), link.target.get("tx"))
            if not write_char or not notify_char:
                raise RuntimeError("characteristics not found (service/rx/tx)")
            link.write_char, link.notify_char = write_char, notify_char
            self._iface(self.bus, notify_char, GATT_CHAR_IFACE).StartNotify()
        except (dbus.exceptions.DBusException, RuntimeError) as exc:
            self.emit_error("enable notifications: %s" % exc, mac=link.mac)
            self.close_link(link, emit=True, reason="timeout", schedule=True)
            return
        self._drop_signal(link, "_char_signal")
        link._char_signal = self.bus.add_signal_receiver(
            lambda *a, **kw: self._on_char_props(link, *a, **kw),
            bus_name=BLUEZ, dbus_interface=DBUS_PROPS,
            signal_name="PropertiesChanged", path=notify_char)
        link.connecting = False
        link.pending_connect = False
        link.polling = False
        link.connected_at = time.time()
        link.mtu = int(link.target.get("mtu") or DEFAULT_MTU)
        link.set_state("connected")
        self.info("connected to", link.mac, "mtu", link.mtu)
        self.emit({
            "event": "connected",
            "mac": link.mac,
            "mtu": link.mtu,
            "service": link.target.get("service"),
            "rx": link.target.get("rx"),
            "tx": link.target.get("tx"),
        })
        # Say who is on the other end; the watch prints this in the net room.
        # Sent a few times: the watch's radio sleeps, so a single write can land
        # in a gap. Re-sent on every reconnect for the same reason.
        for delay in (150, 1200, 2500):
            GLib.timeout_add(delay, self._send_hello, link)
        # A send that was queued while this link was coming up goes now.
        self._pump_tx(link)

    def _send_hello(self, link):
        if self.links.get(link.mac) is not link or not link.connected():
            return False
        self._queue_tx(link, json.dumps({"type": "hello", "name": self.host_name}), None)
        return False

    def _resolve_chars(self, device_path, service, rx, tx):
        managed = self._managed()
        write_char = notify_char = None
        service_l = service.lower() if service else None
        rx_l = rx.lower() if rx else None
        tx_l = tx.lower() if tx else None
        for path, ifaces in managed.items():
            char = ifaces.get(GATT_CHAR_IFACE)
            if not char:
                continue
            svc = managed.get(dbus.ObjectPath(str(char.get("Service"))), {}).get(GATT_SERVICE_IFACE, {})
            if str(svc.get("Device")) != device_path:
                continue
            if service_l and str(svc.get("UUID", "")).lower() != service_l:
                continue
            uuid_l = str(char.get("UUID", "")).lower()
            if rx_l and uuid_l == rx_l:
                write_char = str(path)
            if tx_l and uuid_l == tx_l:
                notify_char = str(path)
        return write_char, notify_char

    # ---- reconnect / maintenance ----

    def _schedule_reconnect(self, link):
        if not self.running or not link.auto_reconnect:
            link.next_attempt = 0.0
            link.set_state("idle")
            return
        delay = link.reconnect_delay
        link.reconnect_delay = min(link.reconnect_delay * 2, RECONNECT_MAX)
        link.next_attempt = time.time() + delay
        link.attempt += 1
        link.set_state("reconnecting")

    def _maintain(self):
        if not self.running:
            return False
        now = time.time()
        for link in list(self.links.values()):
            if self.links.get(link.mac) is not link:
                continue
            # A Connect() whose reply never came back must not latch this link:
            # with connecting set, _begin_connect and the retry check both
            # no-op and the link never comes back. Clear the stale attempt,
            # drop the half-open D-Bus object and let the backoff try again.
            if link.connecting and (now - link.connecting_at) > (CONNECT_TIMEOUT_MS / 1000.0 + 5):
                self.info("connect timed out; retrying", link.mac)
                self.close_link(link, emit=True, reason="timeout", schedule=True)
                continue
            # BlueZ is the truth about the link. Without this, a drop that we
            # did not catch as a signal left write_char set and every send failed
            # with "Not connected" against a link that was already gone.
            if link.device_path:
                try:
                    if not self._prop(link.device_path, "Connected"):
                        self.info("link gone; reconnecting", link.mac)
                        self.close_link(link, emit=True, reason="peer", schedule=True)
                        continue
                except dbus.exceptions.DBusException as exc:
                    self.info("link check failed:", link.mac, exc)
                    self.close_link(link, emit=False, reason="peer", schedule=True)
                    continue
            # A link that stood for STABLE_SECONDS resets its backoff; a flap
            # keeps the doubled delay so the retry storm stays bounded.
            if (link.connected() and link.connected_at
                    and (now - link.connected_at) >= STABLE_SECONDS):
                link.reconnect_delay = RECONNECT_START
                link.attempt = 0
            if (link.auto_reconnect and not link.connected() and not link.connecting
                    and not link.pending_connect and now >= link.next_attempt):
                self._begin_connect(link)
            self._expire_sends(link, now)
        return True

    def _on_device_props(self, link, interface, changed, invalidated, **kw):
        if self.links.get(link.mac) is not link:
            return
        if "Connected" in changed and not changed["Connected"]:
            self.info("device disconnected", link.mac)
            self.close_link(link, emit=True, reason="peer", schedule=True)

    # ---- receive (per link, byte-safe) ----

    def _reset_rx(self, link):
        link._rx_parts = None
        link._rx_total = 0
        link._rx_at = 0.0

    def _on_char_props(self, link, interface, changed, invalidated, **kw):
        if self.links.get(link.mac) is not link:
            return
        if "Value" not in changed:
            return
        try:
            data = bytes(bytearray(changed["Value"]))
        except Exception:
            return
        match = FRAME_RE.match(data)
        if not match:
            # a whole message in one notification (a tap, a state request, the
            # step push): pass it straight through
            self._reset_rx(link)
            self.emit({"event": "message", "mac": link.mac,
                       "data": data.decode("utf-8", "replace")})
            return
        index = int(match.group(1))
        total = int(match.group(2))
        body = data[match.end():]
        if total <= 0 or total > RX_MAX_PARTS or index < 0 or index >= total:
            self.info("bad frame header from", link.mac, "; dropped")
            self._reset_rx(link)
            return
        # Fill by index, not by order: parts can arrive out of order or twice,
        # and a single lost part must not wipe the parts already in hand (it did
        # when any disorder reset the buffer, which threw away the whole clip).
        # Only a fresh message (index 0), a different total, or a long pause
        # restarts the buffer; the message is emitted once every part is present.
        # Body parts stay bytes: a UTF-8 character may be split across two BLE
        # notifications, so decoding happens once, on the joined message.
        now = time.time()
        if (index == 0 or link._rx_parts is None or link._rx_total != total
                or (now - link._rx_at) > RX_GAP_SECONDS):
            if link._rx_parts is not None and any(p is None for p in link._rx_parts):
                missing = [i for i, p in enumerate(link._rx_parts) if p is None]
                self.info("%s: %d part(s) of a framed message never arrived: %s"
                          % (link.mac, len(missing), missing[:12]))
            link._rx_parts = [None] * total
            link._rx_total = total
        link._rx_parts[index] = body
        link._rx_at = now
        if any(part is None for part in link._rx_parts):
            return
        parts = link._rx_parts
        self._reset_rx(link)
        self.emit({"event": "message", "mac": link.mac,
                   "data": b"".join(parts).decode("utf-8", "replace")})

    # ---- send (per-link queue, paced on the GLib loop) ----

    def _encode_tx(self, link, message):
        if isinstance(message, str):
            data = message.encode("utf-8")
        elif isinstance(message, (bytes, bytearray)):
            data = bytes(message)
        else:
            data = str(message).encode("utf-8")
        # Deflate a large payload before it goes over the air (see TX_ZLIB_*):
        # the ~25 KB room push is the slow one, and it compresses ~4x. Only when
        # it actually helps - the mark byte would otherwise grow a small message.
        # The flag is per link; a link that asked for no compression never sees
        # the marker.
        if _as_bool(link.target.get("compress"), True) and len(data) >= TX_ZLIB_MIN:
            comp = zlib.compress(data, 6)
            if len(comp) + 1 < len(data):
                data = bytes([TX_ZLIB_MARK]) + comp
        return frame_payload(data, link.mtu)

    def _write_part(self, link, part):
        # Write Without Response: this watch refuses every Write Request
        # (org.bluez.Error.NotPermitted on the D-Bus WriteValue).
        char = self._iface(self.bus, link.write_char, GATT_CHAR_IFACE)
        options = dbus.Dictionary({"type": "command"}, signature="sv")
        value = dbus.Array([dbus.Byte(b) for b in part], signature="y")
        char.WriteValue(value, options)

    def _write_raw(self, link, message):
        """Write one message synchronously, without sleeping.

        Multi-part pacing belongs to the GLib pump (``_pump_tx``); this helper
        exists for a caller already on the loop that needs an immediate small
        write. It deliberately does not ``time.sleep``: blocking here is what
        used to stall every other link during a large send."""
        for part in self._encode_tx(link, message):
            self._write_part(link, part)

    def _queue_tx(self, link, message, msg_id=None):
        if len(link.tx_queue) >= SEND_QUEUE_MAX:
            self.emit_error("send queue full", mac=link.mac, code="queue_full")
            return False
        deadline = None if link.connected() else time.time() + SEND_QUEUE_TTL
        link.tx_queue.append({"message": message, "id": msg_id,
                              "deadline": deadline})
        if link.connected():
            self._pump_tx(link)
        return True

    def _pump_tx(self, link):
        if self.links.get(link.mac) is not link or link.tx_active:
            return False
        if not link.connected():
            return False
        while link.tx_queue:
            item = link.tx_queue.popleft()
            if item.get("deadline") and time.time() >= item["deadline"]:
                self.emit_error("not connected", mac=link.mac, code="not_connected")
                continue
            try:
                parts = self._encode_tx(link, item["message"])
            except Exception as exc:
                self.emit_error("write: %s" % exc, mac=link.mac)
                continue
            link.tx_item = item
            link.tx_parts = parts
            link.tx_index = 0
            link.tx_active = True
            # Write one part now, then yield. A single D-Bus WriteValue is
            # small even when the message is 25 KB; the GLib loop stays free.
            self._pump_step(link)
            return True
        return False

    def _pump_step(self, link):
        if self.links.get(link.mac) is not link or not link.tx_active:
            return False
        if not link.connected():
            # The link went away mid-message; the rest of the queue waits for
            # the reconnect and expires if it never comes.
            link.tx_active = False
            link.tx_item = None
            link.tx_parts = []
            link.tx_index = 0
            return False
        try:
            self._write_part(link, link.tx_parts[link.tx_index])
        except dbus.exceptions.DBusException as exc:
            link.tx_active = False
            link.tx_item = None
            link.tx_parts = []
            link.tx_index = 0
            self.emit_error("write: %s" % exc, mac=link.mac)
            GLib.idle_add(self._pump_tx, link)
            return False
        link.tx_index += 1
        if link.tx_index < len(link.tx_parts):
            GLib.timeout_add(TX_PART_INTERVAL_MS, self._pump_step, link)
            return False
        item = link.tx_item
        link.tx_active = False
        link.tx_item = None
        link.tx_parts = []
        link.tx_index = 0
        event = {"event": "sent", "mac": link.mac}
        if item is not None and item.get("id") is not None:
            event["id"] = item["id"]
        self.emit(event)
        if link.tx_queue:
            GLib.idle_add(self._pump_tx, link)
        return False

    def _fail_pending(self, link):
        if not link.tx_queue and not link.tx_active:
            return
        link.tx_queue.clear()
        link.tx_active = False
        link.tx_item = None
        link.tx_parts = []
        link.tx_index = 0
        self.emit_error("not connected", mac=link.mac, code="not_connected")

    def _expire_sends(self, link, now):
        if link.connected() or not link.tx_queue:
            return
        keep = deque()
        expired = False
        for item in link.tx_queue:
            if item.get("deadline") and now >= item["deadline"]:
                expired = True
            else:
                keep.append(item)
        link.tx_queue = keep
        if expired:
            self.emit_error("not connected", mac=link.mac, code="not_connected")

    def send(self, message, mac=None, msg_id=None):
        if message is None:
            message = ""
        primary = self._primary()
        if not mac:
            # No MAC means the primary (most recently connected) link, exactly
            # as v1 clients expect.
            if primary is None:
                self.emit_error("not connected")
                return
            link = primary
        else:
            mac = _mac(mac)
            link = self.links.get(mac)
            if link is None:
                stored = load_targets().get(mac)
                if stored is None:
                    self.emit_error("not connected", mac=mac, code="not_connected")
                    return
                if not self._admit_link():
                    self.emit_error("not connected", mac=mac, code="too_many_links")
                    return
                link = Link(stored, auto_reconnect=True)
                self.links[mac] = link
            if not link.connected():
                # Queue briefly and start this link only. No other link is
                # touched, and an existing connected link is never torn down.
                if not link.auto_reconnect:
                    link.auto_reconnect = True
                    link.next_attempt = 0.0
                if not link.connecting and not link.pending_connect and time.time() >= link.next_attempt:
                    self._begin_connect(link)
                self._queue_tx(link, message, msg_id)
                return
        self._queue_tx(link, message, msg_id)

    # ---- status / disconnect ----

    def _link_view(self, link):
        now = time.time()
        # Derive the state from the link's real flags, not only the last value
        # set by a transition: a link with a write char and device path is
        # connected even if a status request races a just-returned callback.
        if link.connected():
            state = "connected"
        elif link.connecting or link.pending_connect:
            state = "connecting"
        elif link.auto_reconnect and link.state == "reconnecting":
            state = "reconnecting"
        else:
            state = "idle"
        next_retry_ms = 0
        if state == "reconnecting" and link.next_attempt > now:
            next_retry_ms = int((link.next_attempt - now) * 1000)
        return {
            "mac": link.mac,
            "state": state,
            "connected": link.connected(),
            "mtu": link.mtu,
            "service": link.target.get("service"),
            "rx": link.target.get("rx"),
            "tx": link.target.get("tx"),
            "since": int(link.since),
            "attempt": link.attempt,
            "next_retry_ms": max(0, next_retry_ms),
        }

    def status(self):
        primary = self._primary()
        links = [self._link_view(link) for link in self.links.values()]
        # Top-level fields stay the primary link so v1 clients keep working.
        self.emit({
            "event": "status",
            "protocol": 2,
            "connected": bool(primary),
            "mac": primary.mac if primary else None,
            "mtu": primary.mtu if primary else DEFAULT_MTU,
            "count": len(links),
            "links": links,
        })

    def disconnect(self, mac=None, all_links=False):
        if all_links or not mac:
            links = list(self.links.values())
            for link in links:
                link.auto_reconnect = False
                link.next_attempt = 0.0
                self._fail_pending(link)
                self.close_link(link, emit=True, reason="local", schedule=False)
            self.links.clear()
            if not self._any_waiting():
                self._stop_discovery("connect")
            self.status()
            return
        mac = _mac(mac)
        link = self.links.get(mac)
        if link is None:
            self.status()
            return
        was_active = (link.connected() or link.connecting or link.pending_connect
                      or link.state == "reconnecting")
        link.auto_reconnect = False
        link.next_attempt = 0.0
        self._fail_pending(link)
        self.close_link(link, emit=True, reason="local", schedule=False)
        link.set_state("idle")
        if not was_active:
            self.status()

    def _drop_signal(self, link, attr):
        # add_signal_receiver hands back a SignalMatch; keep it and .remove() it
        # before adding another. The old code called remove_signal_receiver()
        # with the match object where a handler belongs (and the wrong iface), so
        # the removal always failed: every reconnect stacked a fresh receiver on
        # the same path and each notification was delivered once per accumulated
        # copy -- a single tap landed 7-12 times.
        sig = getattr(link, attr, None)
        if sig is not None:
            try:
                sig.remove()
            except Exception:
                pass
            setattr(link, attr, None)

    def close_link(self, link, emit, reason="local", status=0, schedule=True):
        was_active = bool(link.device_path or link.connecting or link.pending_connect
                          or link.state in ("connected", "reconnecting"))
        self._drop_signal(link, "_char_signal")
        self._drop_signal(link, "_device_signal")
        self._reset_rx(link)   # a half-received clip cannot span a reconnect
        old_path = link.device_path
        # a link that stood a while gets a prompt first retry; a flap keeps the
        # doubled delay so the retry storm stays bounded (see STABLE_SECONDS)
        if old_path and link.connected_at and (time.time() - link.connected_at) >= STABLE_SECONDS:
            link.reconnect_delay = RECONNECT_START
            link.attempt = 0
        link.connected_at = 0.0
        link.write_char = None
        link.notify_char = None
        link.device_path = None
        link.connecting = False
        link.pending_connect = False
        link.polling = False
        # A partial outbound message cannot be resumed; the rest of the queue
        # waits for the next link-up.
        link.tx_active = False
        link.tx_item = None
        link.tx_parts = []
        link.tx_index = 0
        if old_path:
            try:
                self._iface(self.bus, old_path, DEVICE_IFACE).Disconnect()
            except dbus.exceptions.DBusException:
                pass
        if schedule and link.auto_reconnect:
            self._schedule_reconnect(link)
        else:
            link.next_attempt = 0.0
            link.set_state("idle")
        if emit and was_active:
            next_retry_ms = 0
            if schedule and link.auto_reconnect and link.next_attempt:
                next_retry_ms = max(0, int((link.next_attempt - time.time()) * 1000))
            self.emit({
                "event": "disconnected",
                "mac": link.mac,
                "status": int(status),
                "reason": reason,
                "next_retry_ms": next_retry_ms,
            })
        if not self._any_waiting():
            self._stop_discovery("connect")

    # ---- command dispatch (always on the GLib loop) ----

    def _handle(self, cmd):
        name = cmd.get("cmd", "")
        self.info("cmd:", name, cmd.get("mac", "") or "")
        if name == "scan":
            self._start_scan(int(cmd.get("seconds", 8) or 8))
        elif name == "connect":
            self.connect(cmd.get("mac"), cmd.get("service"), cmd.get("rx"),
                         cmd.get("tx"), cmd.get("mtu"), cmd.get("compress"))
        elif name == "send":
            self.send(cmd.get("message", ""), cmd.get("mac"), cmd.get("id"))
        elif name == "disconnect":
            self.disconnect(cmd.get("mac"), bool(cmd.get("all")))
        elif name == "status":
            self.status()
        elif name == "shutdown":
            self.shutdown()
        else:
            self.emit_error("unknown command: %s" % name)

    # ---- sockets ----

    def _accept_loop(self):
        while self.running:
            try:
                conn, _addr = self.server.accept()
            except OSError:
                if not self.running:
                    return
                time.sleep(0.2)
                continue
            with self.clients_lock:
                self.clients.add(conn)
            # Not logged: the dashboard and `status` poll the port every couple of
            # seconds, so a per-connection line would bury the real events.
            GLib.idle_add(self.status)
            threading.Thread(target=self._client_reader, args=(conn,), daemon=True).start()

    def _client_reader(self, conn):
        buf = b""
        try:
            while self.running:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        cmd = json.loads(line.decode("utf-8"))
                    except ValueError as exc:
                        GLib.idle_add(self.emit_error, "bad command: %s" % exc)
                        continue
                    GLib.idle_add(self._handle, cmd)
        except OSError:
            pass
        finally:
            with self.clients_lock:
                self.clients.discard(conn)
            try:
                conn.close()
            except OSError:
                pass

    # ---- lifecycle ----

    def write_pidfile(self):
        try:
            os.makedirs(os.path.dirname(ble_pid_path()), exist_ok=True)
            with open(ble_pid_path(), "w", encoding="utf-8") as fh:
                fh.write(str(os.getpid()))
        except OSError:
            pass

    def remove_pidfile(self):
        try:
            os.remove(ble_pid_path())
        except OSError:
            pass

    def shutdown(self):
        self.info("shutting down")
        self.running = False
        for link in list(self.links.values()):
            link.auto_reconnect = False
            try:
                self.close_link(link, emit=False, reason="local", schedule=False)
            except Exception:
                pass
        self.links.clear()
        try:
            self._stop_discovery(self.discovery_owner)
        except Exception:
            pass
        try:
            if self.server:
                self.server.close()
        except OSError:
            pass
        with self.clients_lock:
            for sock in list(self.clients):
                try:
                    sock.close()
                except OSError:
                    pass
            self.clients.clear()
        if self.loop is not None:
            self.loop.quit()

    def _restore_link(self, target):
        self.connect(target.get("mac"), target.get("service"), target.get("rx"),
                     target.get("tx"), int(target.get("mtu") or 0),
                     target.get("compress", True))
        return False

    def run(self):
        if not HAVE_BLUEZ:
            sys.stderr.write("jawnos-bt-daemon: needs python3-dbus and PyGObject\n")
            return 2
        self.start_bluez()
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        # Bind IPv4 loopback explicitly, like the Android daemon.
        self.server.bind(("127.0.0.1", self.port))
        self.server.listen(8)
        self.write_pidfile()
        self.info("listening on 127.0.0.1:%d" % self.port)

        threading.Thread(target=self._accept_loop, daemon=True).start()
        GLib.timeout_add(1000, self._maintain)

        # Hands-free receive: re-acquire the newest stored targets, as the
        # Android daemon does with its stored target. Stagger them so four
        # restores do not all hit the controller in the same tick.
        stored = sorted(load_targets().values(),
                        key=lambda target: target.get("updated", 0),
                        reverse=True)[:MAX_LINKS]
        for index, target in enumerate(stored):
            GLib.timeout_add(1500 + index * 500, self._restore_link, dict(target))

        self.loop = GLib.MainLoop()
        try:
            self.loop.run()
        finally:
            self.remove_pidfile()
        self.info("stopped")
        return 0


# --------------------------------------------------------------------------
# a one-shot client (used by core.stop_ble and the CLI)
# --------------------------------------------------------------------------

def send_command(command, wait_event=None, timeout=5.0):
    """Connect briefly, send one command, optionally wait for an event."""
    try:
        sock = socket.create_connection(("127.0.0.1", BRIDGE_PORT), timeout=timeout)
    except OSError:
        return None
    sock.settimeout(timeout)
    result = None
    try:
        sock.sendall((json.dumps(command) + "\n").encode("utf-8"))
        if wait_event is None:
            return None
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
                result = event
                if event.get("event") == wait_event:
                    return result
    finally:
        try:
            sock.close()
        except OSError:
            pass
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description="JawnOS BLE bridge (Linux)")
    parser.add_argument("--port", type=int, default=BRIDGE_PORT,
                        help="loopback control port (default %d)" % BRIDGE_PORT)
    args = parser.parse_args(argv)

    def log(*parts):
        # stderr is redirected to the daemon log by whoever started us, so
        # always write -- a silent bridge is impossible to debug.
        stamp = time.strftime("%H:%M:%S")
        sys.stderr.write("[%s] [jawnos-bt] %s\n" % (stamp, " ".join(str(p) for p in parts)))
        sys.stderr.flush()

    return Bridge(port=args.port, log=log).run()


if __name__ == "__main__":
    sys.exit(main())
