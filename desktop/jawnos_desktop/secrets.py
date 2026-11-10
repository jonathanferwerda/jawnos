"""Compatibility import for the desktop's ticket store.

The implementation moved to :mod:`jawnos_desktop.core_secrets` so the Secret
Service / Keychain / Credential Manager backends have one seam. This module
keeps the ``from . import secrets`` spelling used by the CLI, the Qt panel and
usage reporting.
"""

from .core_secrets import clear, describe, load, mask, store

__all__ = ["store", "load", "clear", "mask", "describe"]
