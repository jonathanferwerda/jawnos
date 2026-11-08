"""Whether this machine really carries a GPS receiver.

A machine with no receiver still gets a position from its location service --
GeoClue's, the ISP's coarse one -- which the house deliberately disregards, so
geolocation is denied rather than let that through. Opt in explicitly with
``"gps": true`` in config.json (or name the device with ``"gps_device"``);
otherwise a running gpsd or a receiver named on the USB bus is taken as the
tell.

This is the rule the WebKitGTK view carried, moved out of the Qt shell so it
can be tested without the Qt bindings.
"""

import os
import subprocess

from . import core

# Where a running gpsd publishes its socket.
GPSD_SOCKETS = ("/run/gpsd.sock", "/var/run/gpsd.sock")

# What a GPS receiver calls itself on the USB bus.
USB_MARKERS = ("gps", "u-blox", "ublox", "sirf", "globaltop", "quectel")


def _usb_devices():
    """``lsusb``'s output, lower-cased; empty when it cannot be read."""
    try:
        return subprocess.run(
            ["lsusb"], capture_output=True, text=True, timeout=3).stdout.lower()
    except Exception:
        return ""


def has_gps(jawn_dir, sockets=None, usb=None):
    """Whether this machine really carries a GPS receiver (see the module text).

    ``sockets`` and ``usb`` override the gpsd socket list and the USB listing;
    they exist for the test, which cannot depend on either.
    """
    try:
        config = core.read_app_config(jawn_dir) if jawn_dir else {}
    except Exception:
        config = {}
    if isinstance(config, dict):
        if config.get("gps"):
            return True
        device = config.get("gps_device")
        if device and os.path.exists(str(device)):
            return True
    for sock in (GPSD_SOCKETS if sockets is None else sockets):
        if os.path.exists(sock):
            return True
    devices = _usb_devices() if usb is None else usb
    return any(mark in devices for mark in USB_MARKERS)
