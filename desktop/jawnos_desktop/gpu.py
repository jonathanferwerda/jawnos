"""Graphics setup for the Qt WebEngine shell: keep the embedded GPU in use.

The WebKitGTK shell's rules live in :mod:`webview` because WebKit reads a
different set of switches, and its Skylake/X11 default is *software* rendering
(a workaround for WebKit's accelerated backing store). Chromium needs the
opposite: a blocklisted older Intel GPU must not be left on SwiftShader, and
the raster work belongs on the card so scrolling stays smooth when the machine
is busy.

Two knobs are set here, both before Qt WebEngine initialises:

``LIBVA_DRIVER_NAME=iHD``
    Hardware video decode on an Intel Gen9+ GPU. The table sets this by hand
    today and the laptop does not, although both have ``intel-media-driver``.
    It is only set when an Intel card, a render node and the iHD driver are all
    present, and never over a value the environment already chose.

``QTWEBENGINE_CHROMIUM_FLAGS``
    ``--ignore-gpu-blocklist`` and ``--enable-gpu-rasterization``. Append-only:
    a flag the user or an environment already set is never replaced, and
    ``--disable-gpu`` in the real environment wins outright. ``--enable-zero-copy``
    is deliberately not added: it is the flag most likely to flicker on an older
    Intel X11 compositor, and it is one line in ``qt.env`` for anyone who wants
    it.

Escape hatches, in this order (the real environment always wins):

* ``~/.config/jawnos/webkit.env`` -- its non-``WEBKIT_*`` keys are honoured, so
  ``JAWNOS_GPU`` and ``LIBVA_DRIVER_NAME`` carry across from the GTK shell. Its
  ``WEBKIT_*`` switches mean nothing to Chromium and are skipped.
* ``~/.config/jawnos/qt.env`` -- ``KEY=VALUE`` per line, ``#`` comments; read
  after ``webkit.env``, so it wins.
* ``JAWNOS_GPU=0`` asks for the software path (``--disable-gpu``); unset or any
  truthy value keeps the GPU flags.
"""

import glob
import os

from . import core

INTEL_VENDOR = "0x8086"

# Where the distros put their VA-API drivers (Arch, Debian, Fedora).
_VA_DRIVER_DIRS = (
    "/usr/lib/dri",
    "/usr/lib64/dri",
    "/usr/lib/x86_64-linux-gnu/dri",
    "/usr/lib/aarch64-linux-gnu/dri",
)

# GPU flags for a working card. Kept conservative: these two are safe on Intel
# Mesa and directly address the two things the GTK fixes were about -- using
# the card at all, and keeping raster work off the CPU under load.
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
    filename = "%s_drv_video.so" % name
    return any(os.path.exists(os.path.join(directory, filename))
               for directory in _VA_DRIVER_DIRS)


def prepare_env(environ=None, config_dir=None):
    """Apply the graphics environment; return the keys this call set.

    ``environ`` defaults to ``os.environ``. The shell calls this before
    creating the ``QApplication``: Qt WebEngine reads both variables when it
    initialises. Nothing in the real environment is overwritten.
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

    if (has_intel_gpu() and has_render_node()
            and "LIBVA_DRIVER_NAME" not in environ and has_va_driver("iHD")):
        environ["LIBVA_DRIVER_NAME"] = "iHD"
        applied["LIBVA_DRIVER_NAME"] = "iHD"

    flags = environ.get("QTWEBENGINE_CHROMIUM_FLAGS", "")
    if "--disable-gpu" in flags:
        # An explicit choice, from the environment or qt.env: leave it alone.
        return applied
    software = "JAWNOS_GPU" in environ and not _truthy(environ.get("JAWNOS_GPU"))
    additions = _SOFTWARE_FLAGS if software else _GPU_FLAGS
    environ["QTWEBENGINE_CHROMIUM_FLAGS"] = (flags + " " + " ".join(additions)).strip()
    applied["QTWEBENGINE_CHROMIUM_FLAGS"] = environ["QTWEBENGINE_CHROMIUM_FLAGS"]
    return applied
