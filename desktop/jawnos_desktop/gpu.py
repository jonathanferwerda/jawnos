"""Graphics setup for the Qt WebEngine shell: keep the embedded GPU in use.

Chromium needs a blocklisted older GPU not to be left on SwiftShader, and the
raster work belongs on the card so scrolling stays smooth when the machine is
busy.

Two knobs are set here, both before Qt WebEngine initialises:

``LIBVA_DRIVER_NAME``
    Hardware video decode. The driver follows the DRM vendor: ``iHD`` (or
    ``i965``) on Intel, ``radeonsi`` on AMD, ``nvidia`` on NVIDIA when
    libva-nvidia-driver is installed. Virtual GPUs (virtio, bochs, VMware,
    VirtualBox, qxl) have no VA-API driver, and nouveau has none either, so
    those are left unset. A value the environment already chose is never
    replaced, and a driver is named only when its ``*_drv_video.so`` is
    actually installed.

``QTWEBENGINE_CHROMIUM_FLAGS``
    ``--ignore-gpu-blocklist`` and ``--enable-gpu-rasterization`` on a real
    card with a render node. A machine with no render node, or only a virtual
    display GPU, gets the software path (``--disable-gpu`` and
    ``--disable-gpu-compositing``) instead, so Chromium does not spin a
    failing GPU process; the page still renders. Append-only: a flag the user
    or an environment already set is never replaced, and ``--disable-gpu`` in
    the real environment wins outright. ``--enable-zero-copy`` is deliberately
    not added: it is the flag most likely to flicker on an older Intel X11
    compositor, and it is one line in ``qt.env`` for anyone who wants it.

Escape hatches, in this order (the real environment always wins):

* ``~/.config/jawnos/webkit.env`` -- kept from the old GTK shell. Only its
  non-``WEBKIT_*`` keys are honoured, so ``JAWNOS_GPU`` and
  ``LIBVA_DRIVER_NAME`` still carry across; the ``WEBKIT_*`` switches mean
  nothing to Chromium and are skipped.
* ``~/.config/jawnos/qt.env`` -- ``KEY=VALUE`` per line, ``#`` comments; read
  after ``webkit.env``, so it wins.
* ``JAWNOS_GPU=0`` asks for the software path (``--disable-gpu``); any truthy
  value keeps -- or forces -- the GPU flags, even on a virtual card; unset lets
  the hardware decide.
"""

import glob
import os

from . import core

INTEL_VENDOR = "0x8086"

# DRM vendor IDs, mapped to the family that picks a VA-API driver. The virtual
# IDs are kept separate: those cards expose a render node but have no decode.
DRM_VENDORS = {
    "0x8086": "intel",
    "0x1002": "amd",
    "0x10de": "nvidia",
    "0x1af4": "virtio",
    "0x1234": "bochs",
    "0x15ad": "vmware",
    "0x80ee": "virtualbox",
    "0x1b36": "qxl",
}
VIRTUAL_VENDORS = frozenset(("virtio", "bochs", "vmware", "virtualbox", "qxl"))

# Where the distros put their VA-API drivers (Arch, Debian, Fedora).
_VA_DRIVER_DIRS = (
    "/usr/lib/dri",
    "/usr/lib64/dri",
    "/usr/lib/x86_64-linux-gnu/dri",
    "/usr/lib/aarch64-linux-gnu/dri",
)
_VA_DRIVER_SUFFIX = "_drv_video.so"

# GPU flags for a working card. Kept conservative: these two are safe on the
# Mesa drivers and directly address the two things the old workarounds were
# about -- using the card at all, and keeping raster work off the CPU under load.
_GPU_FLAGS = ("--ignore-gpu-blocklist", "--enable-gpu-rasterization")
_SOFTWARE_FLAGS = ("--disable-gpu", "--disable-gpu-compositing")


def _truthy(value):
    """A shell-style boolean: unset, empty, 0/false/no/off are false."""
    return bool(value) and str(value).strip().lower() not in ("0", "false", "no", "off")


def read_env_file(path):
    """``KEY=VALUE`` lines from a small env file, ignoring comments."""
    values = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except OSError:
        return values
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def drm_cards():
    """``(vendor, device)`` pairs, lower-case hex, for the DRM cards present."""
    cards = []
    for path in glob.glob("/sys/class/drm/card[0-9]*/device"):
        try:
            with open(os.path.join(path, "vendor"), "r", encoding="ascii") as handle:
                vendor = handle.read().strip().lower()
            with open(os.path.join(path, "device"), "r", encoding="ascii") as handle:
                device = handle.read().strip().lower()
        except OSError:
            continue
        cards.append((vendor, device))
    return cards


def has_intel_gpu():
    return any(vendor == INTEL_VENDOR for vendor, _device in drm_cards())


def has_render_node():
    return bool(glob.glob("/dev/dri/renderD*"))


def has_va_driver(name="iHD"):
    filename = "%s%s" % (name, _VA_DRIVER_SUFFIX)
    return any(os.path.exists(os.path.join(directory, filename))
               for directory in _VA_DRIVER_DIRS)


def _card_vendors(cards=None):
    """Vendor IDs, lower-case hex, from sysfs or an injection.

    An injected card may be a bare vendor string or the ``(vendor, device)``
    pair :func:`drm_cards` returns.
    """
    if cards is None:
        cards = drm_cards()
    vendors = []
    for card in cards:
        if isinstance(card, (tuple, list)):
            card = card[0] if card else ""
        value = str(card).strip().lower()
        if value:
            vendors.append(value)
    return vendors


def _render_nodes(render_nodes=None):
    """Render-node paths from ``/dev/dri`` or an injection.

    An injected value may be a list of paths, a number of nodes, or a boolean.
    """
    if render_nodes is None:
        return glob.glob("/dev/dri/renderD*")
    if isinstance(render_nodes, bool):
        return ["/dev/dri/renderD128"] if render_nodes else []
    if isinstance(render_nodes, int):
        return ["/dev/dri/renderD%d" % (128 + index)
                for index in range(render_nodes)]
    return [str(node) for node in render_nodes]


def _driver_names(drivers=None):
    """Installed VA-API driver names (``iHD`` for ``iHD_drv_video.so``)."""
    if drivers is None:
        names = set()
        for directory in _VA_DRIVER_DIRS:
            try:
                entries = os.listdir(directory)
            except OSError:
                continue
            for entry in entries:
                if entry.endswith(_VA_DRIVER_SUFFIX):
                    names.add(entry[:-len(_VA_DRIVER_SUFFIX)])
        return names
    if isinstance(drivers, dict):
        drivers = [name for name, present in drivers.items() if present]
    names = set()
    for name in drivers:
        value = str(name).strip()
        if value.endswith(_VA_DRIVER_SUFFIX):
            value = value[:-len(_VA_DRIVER_SUFFIX)]
        if value:
            names.add(value)
    return names


def _only_virtual(cards=None):
    """True when every recognised card is a virtual display GPU."""
    families = {DRM_VENDORS.get(vendor, "unknown")
                for vendor in _card_vendors(cards)}
    return bool(families) and families <= VIRTUAL_VENDORS


def choose_vaapi_driver(cards=None, render_nodes=None, drivers=None):
    """The VA-API driver for the hardware present, or ``None``.

    Decode is a render-node operation, so a machine without one gets no driver.
    Intel prefers ``iHD`` (Gen9+) and falls back to ``i965``; AMD uses Mesa's
    ``radeonsi``; NVIDIA only has VA-API through libva-nvidia-driver. A virtual
    GPU -- and nouveau, which has no VA-API -- leaves the variable unset.
    """
    if not _render_nodes(render_nodes):
        return None
    families = {DRM_VENDORS.get(vendor, "unknown")
                for vendor in _card_vendors(cards)}
    installed = _driver_names(drivers)
    if "intel" in families:
        for name in ("iHD", "i965"):
            if name in installed:
                return name
    if "amd" in families and "radeonsi" in installed:
        return "radeonsi"
    if "nvidia" in families and "nvidia" in installed:
        return "nvidia"
    return None


def prepare_env(environ=None, config_dir=None, cards=None,
                render_nodes=None, drivers=None):
    """Apply the graphics environment; return the keys this call set.

    ``environ`` defaults to ``os.environ``. The shell calls this before
    creating the ``QApplication``: Qt WebEngine reads both variables when it
    initialises. Nothing in the real environment is overwritten.

    ``cards``, ``render_nodes`` and ``drivers`` are test seams: they replace
    the sysfs, ``/dev/dri`` and driver-directory lookups so the decisions can
    be exercised without the hardware.
    """
    environ = os.environ if environ is None else environ
    config_dir = config_dir or core.config_dir()

    values = {
        key: value
        for key, value in read_env_file(os.path.join(config_dir, "webkit.env")).items()
        if not key.startswith("WEBKIT_")
    }
    values.update(read_env_file(os.path.join(config_dir, "qt.env")))
    real = set(environ)
    applied = {}
    for key, value in values.items():
        if key not in real:
            environ[key] = value
            applied[key] = value

    if "LIBVA_DRIVER_NAME" not in environ:
        driver = choose_vaapi_driver(
            cards=cards, render_nodes=render_nodes, drivers=drivers)
        if driver:
            environ["LIBVA_DRIVER_NAME"] = driver
            applied["LIBVA_DRIVER_NAME"] = driver

    flags = environ.get("QTWEBENGINE_CHROMIUM_FLAGS", "")
    if "--disable-gpu" in flags:
        # An explicit choice, from the environment or qt.env: leave it alone.
        return applied
    if "JAWNOS_GPU" in environ:
        software = not _truthy(environ.get("JAWNOS_GPU"))
    else:
        software = not _render_nodes(render_nodes) or _only_virtual(cards)
    additions = _SOFTWARE_FLAGS if software else _GPU_FLAGS
    environ["QTWEBENGINE_CHROMIUM_FLAGS"] = (flags + " " + " ".join(additions)).strip()
    applied["QTWEBENGINE_CHROMIUM_FLAGS"] = environ["QTWEBENGINE_CHROMIUM_FLAGS"]
    return applied
