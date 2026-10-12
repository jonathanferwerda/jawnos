"""The JawnOS BLE bridge for Linux.

This is the Linux twin of ``JawnBleService.java`` in the JawnOS Android API app.
It is a real Bluetooth LE *central* (built on BlueZ over D-Bus) that links to an
NUS peripheral -- the watch or a board -- and relays newline-delimited JSON to
and from the rest of jawn.

The wire protocol on the loopback control socket is byte-for-byte the Android
one, so ``scripts/jawn-bt`` and jawn's own Perl listener (``ble_listener_start``)
work against it unchanged:

    listen on 127.0.0.1:45999

    commands (one JSON object per line, from any client):
        {"cmd":"scan","seconds":8}
        {"cmd":"connect","mac":"..","service":"..","rx":"..","tx":"..","mtu":512}
        {"cmd":"send","message":".."}
        {"cmd":"disconnect"} | {"cmd":"status"} | {"cmd":"shutdown"}

    events (one JSON object per line, to every client):
        {"event":"status","connected":bool,"mac":..|null,"mtu":n}
        {"event":"scan","mac":..,"name":..|null,"rssi":n}
        {"event":"scan_done"}
        {"event":"error","message":".."}
        {"event":"connected","mac":..,"mtu":n}
        {"event":"disconnected","status":n}
        {"event":"message","data":".."}
        {"event":"sent"}

Payload framing matches the Android daemon and the watch firmware exactly: a
payload too big for one write is split as ``<i>/<n>:`` + chunk (0-based), and the
watch reassembles it (see jw.ino::ble_frame_ingest).

All Bluetooth work runs on the GLib main loop; the only threads are the socket
accept loop and one reader per client, which hand commands to the loop. The
D-Bus connect is asynchronous, so a slow or absent device never freezes the
daemon -- the Android bug this avoids is a worker blocked in a 25 s connect that
could not answer ``shutdown``.
"""

import argparse
import json
import os
import re
import socket
import sys
import threading
import time

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

# The watch frames a payload that will not fit one notification the same way the
# daemon frames a write: "<i>/<n>:" + chunk, 0-based. A notification with no such
# prefix is a whole message. Only the voice clip uses this direction today.
FRAME_RE = re.compile(r"^(\d+)/(\d+):")
RX_GAP_SECONDS = 5.0      # a pause this long means a new message, not a lost part
RX_MAX_PARTS = 4096       # a runaway total cannot grow the buffer without bound


def frame_payload(message, mtu):
    """Split *message* into the daemon's framed chunks.

    Framing matches the Android daemon and the watch firmware
    (``<i>/<n>:`` + chunk). The sizes are pinned to the ATT limit, not the
    Android long-write maths: the watch only accepts **Write Without
    Response**, which cannot be fragmented, so one framed part must fit in
    ``mtu - 3`` bytes. 12 covers the longest ``"<i>/<n>:"`` prefix."""
    data = message.encode("utf-8")
    max_part = max(20, mtu - 3)
    body = max(1, max_part - 12)
    total = 1 if len(data) == 0 else (len(data) + body - 1) // body
    parts = []
    for i in range(total):
        chunk = data[i * body:(i + 1) * body]
        parts.append(("%d/%d:" % (i, total)).encode("ascii") + chunk)
    return parts


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


def load_target():
    try:
        with open(_target_store(), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_target(target):
    try:
        os.makedirs(config_dir(), exist_ok=True)
        with open(_target_store(), "w", encoding="utf-8") as fh:
            json.dump(target, fh, indent=2, sort_keys=True)
    except OSError:
        pass


class Bridge(object):
    def __init__(self, port=BRIDGE_PORT, log=None):
        self.port = port
        self.log = log or (lambda *a: None)
        self.running = True
        self.server = None
        self.clients = set()
        self.clients_lock = threading.Lock()

        self.scanning = False
        self.scan_seen = set()

        self.bus = None
        self.loop = None
        self.om = None
        self.device_path = None
        self.write_char = None
        self.notify_char = None
        self.mtu = DEFAULT_MTU
        self.target = {"mac": None, "service": None, "rx": None, "tx": None, "mtu": 0}
        self.host_name = bridge_name()
        self.auto_reconnect = False
        self.reconnect_delay = RECONNECT_START
        self.next_attempt = 0.0
        self.connecting = False
        self.pending_connect = False
        self.discovery_owner = None
        self._char_signal = None
        self._device_signal = None
        # watch -> daemon reassembly (a framed voice clip arrives in parts)
        self._rx_parts = None
        self._rx_total = 0
        self._rx_at = 0.0

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

    def emit_error(self, message):
        self.info("error:", message)
        self.emit({"event": "error", "message": message})

    def connected(self):
        return bool(self.write_char and self.device_path)

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

    # ---- discovery (shared by scan and connect) ----

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

    # ---- scan ----

    def _on_interfaces_added(self, path, interfaces):
        if self.scanning and DEVICE_IFACE in interfaces:
            self._emit_scan(interfaces[DEVICE_IFACE])

    def _emit_scan(self, props):
        address = str(props.get("Address", "")).upper()
        if not address or address in self.scan_seen:
            return
        self.scan_seen.add(address)
        name = props.get("Alias") or props.get("Name")
        self.emit({
            "event": "scan",
            "mac": address,
            "name": str(name) if name else None,
            "rssi": int(props.get("RSSI", 0) or 0),
        })

    def _start_scan(self, seconds):
        if self.scanning:
            return
        if self._bluetooth_ready() is None:
            return
        self.scanning = True
        self.scan_seen = set()
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
        want = mac.upper()
        for path, props in self._devices().items():
            if str(props.get("Address", "")).upper() == want:
                return path
        return None

    def connect(self, mac, service=None, rx=None, tx=None, mtu=0):
        if not mac:
            self.emit_error("connect: mac required")
            return
        # A connect need not repeat the characteristics every time. An omitted
        # one falls back to the stored target, then to the NUS defaults this
        # bridge exists for. Without this a bare "connect <mac>" overwrote a
        # good stored target with nulls, which service resolution can never
        # match, so the watch stayed unlinked from then on.
        stored = load_target()
        service = service or stored.get("service") or NUS_SERVICE
        rx = rx or stored.get("rx") or NUS_RX
        tx = tx or stored.get("tx") or NUS_TX
        if not mtu:
            mtu = stored.get("mtu") or 512
        # Idempotent: a second connect for the same target (an explicit one on
        # top of the startup auto-connect) must not tear down a connect that is
        # already in flight -- that produced BlueZ "InProgress" churn.
        same = (self.target.get("mac") == mac
                and self.target.get("service") == service
                and self.target.get("rx") == rx
                and self.target.get("tx") == tx)
        if same and (self.connected() or self.pending_connect or self.connecting):
            self.status()
            return
        self.close_link(emit=False)
        self.target = {"mac": mac, "service": service, "rx": rx, "tx": tx, "mtu": mtu}
        self.mtu = mtu if mtu and mtu > 0 else DEFAULT_MTU
        self.auto_reconnect = True
        self.reconnect_delay = RECONNECT_START
        save_target(self.target)
        self._begin_connect()

    def _begin_connect(self):
        # pending_connect covers the whole flow (discovery then connect), so a
        # second queued connect -- our explicit one plus the startup
        # auto-connect, say -- does not spawn a rival discovery timer.
        if self.connecting or self.connected() or self.pending_connect:
            return
        mac = self.target.get("mac")
        if not mac:
            return
        if self._bluetooth_ready() is None:
            self._schedule_reconnect()
            return
        self.pending_connect = True
        path = self.find_device(mac)
        if path:
            self._connect_device(path)
            return
        # Not known yet: discover until it shows up, then connect. Non-blocking
        # so the daemon stays responsive (and stoppable) the whole time.
        self.info("waiting for", mac, "to advertise")
        self._start_discovery("connect")
        GLib.timeout_add(500, self._poll_for_device)

    def _poll_for_device(self):
        # Keep discovery running until the peripheral appears. The watch's radio
        # sleeps, so it advertises only in bursts; a fixed 12 s window with a
        # backoff would keep missing it. A desktop can afford to scan
        # continuously, and stops the moment the device is found or the user
        # disconnects.
        if not self.auto_reconnect or not self.pending_connect:
            self._stop_discovery("connect")
            return False
        if self.connected() or self.connecting:
            self._stop_discovery("connect")
            return False
        path = self.find_device(self.target.get("mac"))
        if path:
            self._stop_discovery("connect")
            # Let bluetoothd actually stop scanning before initiating the link:
            # on some controllers (Intel) a connect issued while the scanner is
            # still winding down aborts with le-connection-abort-by-local.
            GLib.timeout_add(400, self._connect_device, path)
            return False
        return True

    def _connect_device(self, path):
        if self.connecting:
            return
        self.connecting = True
        try:
            device = self._iface(self.bus, path, DEVICE_IFACE)
            device.Connect(
                reply_handler=lambda: self._after_connect(path),
                error_handler=lambda exc: self._connect_failed(exc),
                timeout=CONNECT_TIMEOUT_MS)
        except dbus.exceptions.DBusException as exc:
            self._connect_failed(exc)

    def _connect_failed(self, exc):
        self.connecting = False
        self.pending_connect = False
        self.emit_error("connect failed: %s" % exc)
        self._schedule_reconnect()

    def _after_connect(self, path):
        self.device_path = path
        self.reconnect_delay = RECONNECT_START
        self._drop_signal("_device_signal")
        self._device_signal = self.bus.add_signal_receiver(
            self._on_device_props, bus_name=BLUEZ,
            dbus_interface=DBUS_PROPS, signal_name="PropertiesChanged", path=path)
        GLib.timeout_add(200, self._wait_services, path, time.time() + 10.0)

    def _wait_services(self, path, deadline):
        if self.device_path is None:
            return False
        try:
            resolved = bool(self._prop(path, "ServicesResolved"))
        except dbus.exceptions.DBusException:
            resolved = False
        if resolved or time.time() > deadline:
            self._finish_connect(path)
            return False
        return True

    def _finish_connect(self, path):
        # Connect() returning is not proof the link survived; check before
        # trusting it, or a drop lands as a phantom "connected" state.
        try:
            if not self._prop(path, "Connected"):
                self.connecting = False
                self.pending_connect = False
                self.close_link(emit=False)
                self._schedule_reconnect()
                return
        except dbus.exceptions.DBusException:
            pass
        try:
            write_char, notify_char = self._resolve_chars(
                path, self.target.get("service"), self.target.get("rx"), self.target.get("tx"))
            if not write_char or not notify_char:
                raise RuntimeError("characteristics not found (service/rx/tx)")
            self.write_char, self.notify_char = write_char, notify_char
            self._iface(self.bus, notify_char, GATT_CHAR_IFACE).StartNotify()
        except (dbus.exceptions.DBusException, RuntimeError) as exc:
            self.connecting = False
            self.pending_connect = False
            self.emit_error("enable notifications: %s" % exc)
            self.close_link(emit=False)
            self._schedule_reconnect()
            return
        self._drop_signal("_char_signal")
        self._char_signal = self.bus.add_signal_receiver(
            self._on_char_props, bus_name=BLUEZ,
            dbus_interface=DBUS_PROPS, signal_name="PropertiesChanged", path=notify_char)
        self.connecting = False
        self.pending_connect = False
        self.info("connected to", self.target.get("mac"), "mtu", self.mtu)
        self.emit({"event": "connected", "mac": self.target.get("mac"), "mtu": self.mtu})
        # Say who is on the other end; the watch prints this in the net room.
        # Sent a few times: the watch's radio sleeps, so a single write can land
        # in a gap. Re-sent on every reconnect for the same reason.
        for delay in (150, 1200, 2500):
            GLib.timeout_add(delay, self._send_hello)

    def _send_hello(self):
        if not self.connected():
            return False
        try:
            self._write_raw(json.dumps({"type": "hello", "name": self.host_name}))
        except dbus.exceptions.DBusException as exc:
            self.info("hello write failed:", exc)
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

    def _schedule_reconnect(self):
        if not self.auto_reconnect:
            return
        delay = self.reconnect_delay
        self.reconnect_delay = min(self.reconnect_delay * 2, RECONNECT_MAX)
        self.next_attempt = time.time() + delay

    def _maintain(self):
        # BlueZ is the truth about the link. Without this, a drop that we did
        # not catch as a signal left write_char set and every send failed with
        # "Not connected" against a link that was already gone.
        if self.device_path:
            try:
                if not self._prop(self.device_path, "Connected"):
                    self.info("link gone; reconnecting")
                    self.close_link(emit=True)
            except dbus.exceptions.DBusException as exc:
                self.info("link check failed:", exc)
                self.close_link(emit=False)
        if (self.auto_reconnect and self.target.get("mac") and not self.connected()
                and not self.connecting and not self.pending_connect
                and time.time() >= self.next_attempt):
            self._begin_connect()
        return True

    def _on_device_props(self, interface, changed, invalidated, **kw):
        if "Connected" in changed and not changed["Connected"]:
            self.info("device disconnected")
            self.close_link(emit=True)

    def _reset_rx(self):
        self._rx_parts = None
        self._rx_total = 0
        self._rx_at = 0.0

    def _on_char_props(self, interface, changed, invalidated, **kw):
        if "Value" not in changed:
            return
        try:
            text = bytes(bytearray(changed["Value"])).decode("utf-8", "replace")
        except Exception:
            return
        match = FRAME_RE.match(text)
        if not match:
            # a whole message in one notification (a tap, a state request, the
            # step push): pass it straight through
            self._reset_rx()
            self.emit({"event": "message", "data": text})
            return
        index = int(match.group(1))
        total = int(match.group(2))
        body = text[match.end():]
        if total <= 0 or total > RX_MAX_PARTS or index < 0 or index >= total:
            self.info("bad frame header from the watch; dropped")
            self._reset_rx()
            return
        # Fill by index, not by order: parts can arrive out of order or twice,
        # and a single lost part must not wipe the parts already in hand (it did
        # when any disorder reset the buffer, which threw away the whole clip).
        # Only a fresh message (index 0), a different total, or a long pause
        # restarts the buffer; the message is emitted once every part is present.
        now = time.time()
        if (index == 0 or self._rx_parts is None or self._rx_total != total
                or (now - self._rx_at) > RX_GAP_SECONDS):
            if self._rx_parts is not None and any(p is None for p in self._rx_parts):
                missing = [i for i, p in enumerate(self._rx_parts) if p is None]
                self.info("%d part(s) of a framed message never arrived: %s"
                          % (len(missing), missing[:12]))
            self._rx_parts = [None] * total
            self._rx_total = total
        self._rx_parts[index] = body
        self._rx_at = now
        if any(part is None for part in self._rx_parts):
            return
        parts = self._rx_parts
        self._reset_rx()
        self.emit({"event": "message", "data": "".join(parts)})

    # ---- send ----

    def _write_raw(self, message):
        char = self._iface(self.bus, self.write_char, GATT_CHAR_IFACE)
        # Write Without Response: this watch refuses every Write Request
        # (org.bluez.Error.NotPermitted on the D-Bus WriteValue). It has no ATT
        # ack to throttle us, so pace the chunks to avoid overrunning the
        # peripheral's receive buffer on a big room push.
        options = dbus.Dictionary({"type": "command"}, signature="sv")
        parts = frame_payload(message, self.mtu)
        for index, part in enumerate(parts):
            value = dbus.Array([dbus.Byte(b) for b in part], signature="y")
            char.WriteValue(value, options)
            if index + 1 < len(parts):
                time.sleep(0.015)

    def send(self, message):
        if not self.connected():
            self.emit_error("not connected")
            return
        try:
            self._write_raw(message)
        except dbus.exceptions.DBusException as exc:
            self.emit_error("write: %s" % exc)
            return
        self.emit({"event": "sent"})

    # ---- status / disconnect ----

    def status(self):
        self.emit({
            "event": "status",
            "connected": self.connected(),
            "mac": self.target.get("mac"),
            "mtu": self.mtu,
        })

    def disconnect(self):
        self.auto_reconnect = False
        self.close_link(emit=True)

    def _drop_signal(self, attr):
        # add_signal_receiver hands back a SignalMatch; keep it and .remove() it
        # before adding another. The old code called remove_signal_receiver()
        # with the match object where a handler belongs (and the wrong iface), so
        # the removal always failed: every reconnect stacked a fresh receiver on
        # the same path and each notification was delivered once per accumulated
        # copy -- a single tap landed 7-12 times.
        sig = getattr(self, attr, None)
        if sig is not None:
            try:
                sig.remove()
            except Exception:
                pass
            setattr(self, attr, None)

    def close_link(self, emit):
        self._drop_signal("_char_signal")
        self._drop_signal("_device_signal")
        self._reset_rx()   # a half-received clip cannot span a reconnect
        had = self.device_path
        self.write_char = None
        self.notify_char = None
        self.device_path = None
        self.connecting = False
        self.pending_connect = False
        if had:
            try:
                self._iface(self.bus, had, DEVICE_IFACE).Disconnect()
            except dbus.exceptions.DBusException:
                pass
            if emit:
                self.emit({"event": "disconnected", "status": 0})
            self._schedule_reconnect()

    # ---- command dispatch (always on the GLib loop) ----

    def _handle(self, cmd):
        name = cmd.get("cmd", "")
        self.info("cmd:", name)
        if name == "scan":
            self._start_scan(int(cmd.get("seconds", 8) or 8))
        elif name == "connect":
            self.connect(cmd.get("mac"), cmd.get("service"), cmd.get("rx"),
                         cmd.get("tx"), int(cmd.get("mtu", 0) or 0))
        elif name == "send":
            self.send(cmd.get("message", ""))
        elif name == "disconnect":
            self.disconnect()
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
        self.auto_reconnect = False
        try:
            self.close_link(emit=False)
        except Exception:
            pass
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

        # Hands-free receive: re-acquire the last device, as the Android daemon
        # does with its stored target.
        stored = load_target()
        if stored.get("mac"):
            GLib.timeout_add(1500, lambda: (self.connect(stored.get("mac"),
                           stored.get("service"), stored.get("rx"),
                           stored.get("tx"), stored.get("mtu", 0)), False)[1])

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
