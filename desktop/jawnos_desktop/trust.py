"""Trust only this install's own TLS certificates.

A fresh machine serves a self-signed leaf from ``server/fullchain.pem``; a
machine that joined a house also holds the house CA in ``server/house-ca.pem``
(a peer's leaf is signed by that CA and its chain carries the CA certificate).
Those files are this install's anchors and nothing else is.

The certificate error Qt hands a page is accepted only when at least one
presented certificate hashes to an anchor. An unrelated self-signed
certificate is left rejected, however tempting accepting it would be.

The module imports no toolkit at module level, so a pure test can call
``trusted_digests()`` with a directory of PEM files and the accept decision
with small fake ``error``/``certificate`` objects.
"""

import base64
import hashlib
import os
import re
import threading

try:  # importable without PySide6, like qt_shell
    from PySide6.QtNetwork import QSslCertificate  # noqa: F401
except Exception:  # pragma: no cover - only without PySide6
    QSslCertificate = None

# Anchors, in the tree the Manager runs from. Both may hold several PEM blocks.
CERT_FILES = ("fullchain.pem", "house-ca.pem")

_PEM_BLOCK = re.compile(
    r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", re.DOTALL)
_BEGIN = "-----BEGIN CERTIFICATE-----"
_END = "-----END CERTIFICATE-----"

_state = {"tree": None}
_lock = threading.Lock()


def set_tree(jawn_dir):
    """Record the tree whose ``server/`` holds this install's certificates."""
    tree = os.path.expanduser(jawn_dir) if jawn_dir else None
    with _lock:
        _state["tree"] = tree


def tree():
    """The recorded tree, or None."""
    with _lock:
        return _state["tree"]


def _pem_digests(path):
    """SHA-256 hex digests of every certificate block in one PEM file."""
    try:
        with open(path, "r", encoding="ascii", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return set()
    digests = set()
    for block in _PEM_BLOCK.findall(text):
        body = block.replace(_BEGIN, "").replace(_END, "")
        try:
            der = base64.b64decode("".join(body.split()), validate=True)
        except Exception:
            continue
        if der:
            digests.add(hashlib.sha256(der).hexdigest())
    return digests


def trusted_digests():
    """The digests of this install's anchors; empty when there are none.

    The files are tiny and only read on a certificate error, so they are read
    each time: a rotated certificate is trusted on the first request after it
    lands rather than after a restart.
    """
    jawn_dir = tree()
    if not jawn_dir:
        return set()
    digests = set()
    for name in CERT_FILES:
        digests |= _pem_digests(os.path.join(jawn_dir, "server", name))
    return digests


def _cert_der(cert):
    try:
        der = cert.toDer()
    except Exception:
        return b""
    try:
        return bytes(der)
    except Exception:
        return b""


def _presented_digests(error):
    """Digests of the certificate(s) the engine presented, chain included."""
    certs = []
    chain = getattr(error, "certificateChain", None)
    if callable(chain):
        try:
            certs = list(chain() or [])
        except Exception:
            certs = []
    if not certs:
        certificate = getattr(error, "certificate", None)
        if callable(certificate):
            try:
                cert = certificate()
            except Exception:
                cert = None
            if cert is not None:
                certs = [cert]
    digests = set()
    for cert in certs:
        der = _cert_der(cert)
        if der:
            digests.add(hashlib.sha256(der).hexdigest())
    return digests


def accept_certificate(error):
    """Accept a certificate error only for this install's own certificates."""
    try:
        overridable = getattr(error, "isOverridable", None)
        if callable(overridable) and not overridable():
            return False
        anchors = trusted_digests()
        if not anchors:
            return False
        if not (_presented_digests(error) & anchors):
            return False
        # Qt 6.8 spells it acceptCertificate(); older bindings used accept().
        accept = getattr(error, "acceptCertificate", None)
        if not callable(accept):
            accept = getattr(error, "accept", None)
        if not callable(accept):
            return False
        accept()
        return True
    except Exception:
        return False
