"""Encrypted-at-rest storage for the JawnOS login ticket.

The ticket URL is a live login token (loading it mints the ``president``
session cookie), so it must not sit in a plain file. We store it where the
desktop already keeps secrets:

1. the **Secret Service** (gnome-keyring/kwallet) via ``secret-tool`` -- the
   keyring encrypts it at rest and unlocks it with the login session;
2. failing that, a **Fernet-encrypted file** under the config dir, with the key
   in a 0600 file beside it (obfuscation-grade, but not plaintext).

The embedded view loads whatever ticket is stored here to log in.
"""

import os
import shutil
import subprocess

from . import core

_LABEL = "JawnOS login ticket"
_ATTRS = ("service", "jawnos", "key", "ticket")


# --------------------------------------------------------------------------
# Secret Service (preferred)
# --------------------------------------------------------------------------

def _secret_tool():
    return shutil.which("secret-tool")


def _ss_store(url):
    tool = _secret_tool()
    if not tool:
        return False
    try:
        subprocess.run([tool, "store", "--label", _LABEL] + list(_ATTRS),
                       input=url.encode(), check=True)
        return True
    except (OSError, subprocess.CalledProcessError):
        return False


def _ss_load():
    tool = _secret_tool()
    if not tool:
        return None
    try:
        done = subprocess.run([tool, "lookup"] + list(_ATTRS), capture_output=True)
    except OSError:
        return None
    if done.returncode == 0:
        value = done.stdout.decode("utf-8", "replace").strip()
        return value or None
    return None


def _ss_clear():
    tool = _secret_tool()
    if not tool:
        return
    try:
        subprocess.run([tool, "clear"] + list(_ATTRS), check=False)
    except OSError:
        pass


# --------------------------------------------------------------------------
# Fernet file fallback
# --------------------------------------------------------------------------

def _key_path():
    return os.path.join(core.config_dir(), "ticket.key")


def _enc_path():
    return os.path.join(core.config_dir(), "ticket.enc")


def _fernet(create=False):
    try:
        from cryptography.fernet import Fernet
    except Exception:
        return None
    path = _key_path()
    if os.path.exists(path):
        try:
            with open(path, "rb") as fh:
                return Fernet(fh.read().strip())
        except Exception:
            return None
    if not create:
        return None
    key = Fernet.generate_key()
    os.makedirs(core.config_dir(), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, key)
    finally:
        os.close(fd)
    return Fernet(key)


def _file_store(url):
    box = _fernet(create=True)
    if box is None:
        return False
    try:
        os.makedirs(core.config_dir(), exist_ok=True)
        path = _enc_path()
        with open(path, "wb") as fh:
            fh.write(box.encrypt(url.encode("utf-8")))
        os.chmod(path, 0o600)
        return True
    except OSError:
        return False


def _file_load():
    if not os.path.exists(_enc_path()):
        return None
    box = _fernet(create=False)
    if box is None:
        return None
    try:
        with open(_enc_path(), "rb") as fh:
            return box.decrypt(fh.read()).decode("utf-8")
    except Exception:
        return None


def _file_clear():
    for path in (_enc_path(), _key_path()):
        try:
            os.remove(path)
        except OSError:
            pass


# --------------------------------------------------------------------------
# public API
# --------------------------------------------------------------------------

def store(url):
    url = (url or "").strip()
    if not url:
        return False, "empty ticket"
    if _ss_store(url) or _file_store(url):
        return True, "ticket stored (encrypted)"
    return False, "no keyring and no cryptography available to store it"


def load():
    return _ss_load() or _file_load()


def clear():
    _ss_clear()
    _file_clear()
    return True


def mask(url):
    """A safe rendering for logs/UI: keep the host, hide the token."""
    if not url:
        return ""
    head = url.split("s=", 1)[0]
    return head + "s=\u2026" if "s=" in url else head


def describe():
    url = load()
    if not url:
        return "none stored"
    where = "keyring" if _ss_load() else "encrypted file"
    return "%s (%s)" % (mask(url), where)
