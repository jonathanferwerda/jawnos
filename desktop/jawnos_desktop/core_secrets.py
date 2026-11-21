"""Encrypted-at-rest storage for the JawnOS login ticket.

The ticket URL is a live login token (loading it mints the ``president``
session cookie), so it must not sit in a plain file. We store it where the
desktop already keeps secrets:

1. the **Secret Service** (gnome-keyring/kwallet) via ``secret-tool`` -- the
   keyring encrypts it at rest and unlocks it with the login session;
2. failing that, a **Fernet-encrypted file** under the config dir, with the key
   in a 0600 file beside it (obfuscation-grade, but not plaintext).

The backends are tried in this order:

1. Linux **Secret Service** (gnome-keyring/kwallet) via ``secret-tool``.
2. Windows **DPAPI**, through ``CryptProtectData`` -- the key belongs to this
   Windows user, so a copied file is not a usable ticket.
3. A **Fernet-encrypted file** under the config dir, with the key in a 0600
   file beside it (obfuscation-grade, but not plaintext). This is the last
   resort on every platform.

The embedded view loads whatever ticket is stored here to log in.
"""

import os
import shutil
import subprocess

from .core_paths import config_dir

IS_WINDOWS = os.name == "nt"

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
# Windows DPAPI
# --------------------------------------------------------------------------

_DPAPI_UI_FORBIDDEN = 0x1


def _dpapi_path():
    return os.path.join(config_dir(), "ticket.dpapi")


def _dpapi_blob(data):
    """A DATA_BLOB plus the buffer that owns its bytes."""
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [
            ("cbData", wintypes.DWORD),
            ("pbData", ctypes.POINTER(ctypes.c_char)),
        ]

    buffer = ctypes.create_string_buffer(data, len(data))
    blob = DATA_BLOB(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char)))
    return DATA_BLOB, blob, buffer


def _dpapi_call(protect, data):
    """Protect or unprotect one blob; returns bytes or ``None``.

    The DPAPI functions live in crypt32.dll and the returned memory belongs to
    the caller (``LocalFree``). Both descriptors and the optional entropy are
    left out, so the default user scope protects the ticket.
    """
    if not IS_WINDOWS:
        return None
    try:
        import ctypes
        from ctypes import wintypes

        DATA_BLOB, blob_in, _buffer = _dpapi_blob(data)
        blob_out = DATA_BLOB()
        crypt32 = ctypes.windll.crypt32
        kernel32 = ctypes.windll.kernel32
        kernel32.LocalFree.argtypes = [ctypes.c_void_p]
        if protect:
            crypt32.CryptProtectData.argtypes = [
                ctypes.POINTER(DATA_BLOB), wintypes.LPCWSTR,
                ctypes.POINTER(DATA_BLOB), ctypes.c_void_p, ctypes.c_void_p,
                wintypes.DWORD, ctypes.POINTER(DATA_BLOB),
            ]
            crypt32.CryptProtectData.restype = wintypes.BOOL
            ok = crypt32.CryptProtectData(
                ctypes.byref(blob_in), _LABEL, None, None, None,
                _DPAPI_UI_FORBIDDEN, ctypes.byref(blob_out))
        else:
            crypt32.CryptUnprotectData.argtypes = [
                ctypes.POINTER(DATA_BLOB), ctypes.POINTER(wintypes.LPWSTR),
                ctypes.POINTER(DATA_BLOB), ctypes.c_void_p, ctypes.c_void_p,
                wintypes.DWORD, ctypes.POINTER(DATA_BLOB),
            ]
            crypt32.CryptUnprotectData.restype = wintypes.BOOL
            ok = crypt32.CryptUnprotectData(
                ctypes.byref(blob_in), None, None, None, None,
                _DPAPI_UI_FORBIDDEN, ctypes.byref(blob_out))
        if not ok:
            return None
        try:
            return ctypes.string_at(blob_out.pbData, blob_out.cbData)
        finally:
            kernel32.LocalFree(blob_out.pbData)
    except Exception:
        return None


def _dpapi_store(url):
    if not IS_WINDOWS:
        return False
    payload = _dpapi_call(True, url.encode("utf-8"))
    if payload is None:
        return False
    try:
        os.makedirs(config_dir(), exist_ok=True)
        with open(_dpapi_path(), "wb") as fh:
            fh.write(payload)
        return True
    except OSError:
        return False


def _dpapi_load():
    if not IS_WINDOWS or not os.path.exists(_dpapi_path()):
        return None
    try:
        with open(_dpapi_path(), "rb") as fh:
            payload = fh.read()
    except OSError:
        return None
    plain = _dpapi_call(False, payload)
    if plain is None:
        return None
    try:
        return plain.decode("utf-8").strip() or None
    except UnicodeDecodeError:
        return None


def _dpapi_clear():
    try:
        os.remove(_dpapi_path())
    except OSError:
        pass


# --------------------------------------------------------------------------
# Fernet file fallback
# --------------------------------------------------------------------------

def _key_path():
    return os.path.join(config_dir(), "ticket.key")


def _enc_path():
    return os.path.join(config_dir(), "ticket.enc")


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
    os.makedirs(config_dir(), exist_ok=True)
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
        os.makedirs(config_dir(), exist_ok=True)
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
    if _ss_store(url) or _dpapi_store(url) or _file_store(url):
        return True, "ticket stored (encrypted)"
    return False, "no keyring, DPAPI or cryptography available to store it"


def load():
    return _ss_load() or _dpapi_load() or _file_load()


def clear():
    _ss_clear()
    _dpapi_clear()
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
    if _ss_load():
        where = "keyring"
    elif _dpapi_load():
        where = "Windows DPAPI"
    else:
        where = "encrypted file"
    return "%s (%s)" % (mask(url), where)


def manager_host():
    """The host the stored ticket logs in on.

    The ticket's session cookie is scoped to that host, so the manager must be
    opened from it too -- the loopback address is a different origin and shows
    the login gate. Falls back to loopback when there is no stored ticket."""
    try:
        from urllib.parse import urlparse
        ticket = load()
        if ticket:
            return urlparse(ticket).hostname or "127.0.0.1"
    except Exception:
        pass
    return "127.0.0.1"
