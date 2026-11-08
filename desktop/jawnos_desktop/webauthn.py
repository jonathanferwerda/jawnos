"""The WebAuthn/passkey prompt Qt WebEngine leaves to the embedder.

WebKitGTK drew the browser's passkey UX itself. Qt WebEngine does not: a page
that calls ``navigator.credentials.create``/``get`` makes the engine emit
``QWebEnginePage.webAuthUxRequested`` and wait. Nothing happens -- the
JavaScript promise neither resolves nor rejects -- until the embedding app
renders the prompt, answers each state, or cancels the request.

``install_webauthn(page, window)`` connects that signal for one page. Each
request gets one modal dialog, kept open across the request's states:

    SelectAccount          choose one of the authenticator's resident names
    CollectPin             a password-style field, set/change/challenge
    FinishTokenCollection  "touch your security key" (waiting, no button)
    RequestFailed          the reason in words, then Close
    Completed/Cancelled    close; Qt already owns the outcome

The Qt contract that is easy to get wrong:

* Qt emits ``stateChanged`` several times for the same request. The dialogs are
  updated in place, and a state may arrive after the person has closed one, so
  every handler tolerates a settled request.
* Closing the dialog is a cancel: Qt blocks the page until ``cancel()`` or a
  real answer arrives. ``cancel()`` must be called exactly once, and never
  after Qt reported Completed.
* The text mapping is pure and Qt-free (``request_text``), so it is testable on
  a machine with no PySide6 -- which is also why every ``from PySide6...``
  import lives inside a function.

Older bindings have no signal at all; ``install_webauthn`` returns False there
and the view keeps its previous behaviour.

The Manager can also be opened on a raw IP (``127.0.0.1``). WebAuthn needs a
registrable domain, and the page code itself skips passkeys on a raw address,
so the desktop exercises this only on the house's named host.
"""

# The words the person reads, keyed by the Qt enum member names. Kept as plain
# Python data (no Qt import) so the mapping can be tested without a display.
# This is core UI text, so it is written in English rather than a new key in
# all sixteen catalogs.
STATE_TEXT = {
    "SelectAccount": ("Choose a passkey", ""),
    "CollectPin": ("Security key PIN", ""),
    "FinishTokenCollection": (
        "Touch your security key",
        "Touch your security key now to finish."),
    "RequestFailed": ("Passkey request failed", ""),
    "Completed": ("", ""),
    "Cancelled": ("", ""),
    "NotStarted": ("", ""),
}

PIN_REASON_TEXT = {
    "Set": ("Choose a security key PIN", "Set a PIN for this security key."),
    "Change": ("Change the security key PIN",
               "The key requires a new PIN before it can be used."),
    "Challenge": ("Security key PIN", "Enter the PIN for your security key."),
}

PIN_ERROR_TEXT = {
    "WrongPin": "Wrong PIN.",
    "TooShort": "That PIN is too short.",
    "InvalidCharacters": "That PIN contains characters the key does not accept.",
    "SameAsCurrentPin": "Choose a PIN different from the current one.",
    "InternalUvLocked": "User verification is locked; enter the PIN instead.",
}

FAILURE_TEXT = {
    "Timeout": "The security key did not answer in time. Try again.",
    "KeyNotRegistered": "This security key is not registered with the house.",
    "KeyAlreadyRegistered":
        "This security key is already registered. Use another key "
        "or sign in with the one you have.",
    "SoftPinBlock":
        "Too many wrong PINs. Remove and reinsert the key to unlock it.",
    "HardPinBlock":
        "Too many wrong PINs. The key is locked and must be reset before it "
        "can be used again.",
    "AuthenticatorRemovedDuringPinEntry":
        "The security key was removed during PIN entry. Reinsert it and try "
        "again.",
    "AuthenticatorMissingResidentKeys":
        "This security key cannot store passkeys.",
    "AuthenticatorMissingUserVerification":
        "This security key cannot verify the person using it.",
    "AuthenticatorMissingLargeBlob":
        "This security key does not support the requested feature.",
    "NoCommonAlgorithms":
        "This security key does not support an algorithm the house requires.",
    "StorageFull": "This security key has no room for another passkey.",
    "UserConsentDenied": "The request was declined on the security key.",
    "WinUserCancelled": "The request was cancelled.",
}


def request_text(state, reason="", pin_reason="", relying_party=""):
    """The title and body for one WebAuthn state, as plain strings.

    ``state``, ``reason`` and ``pin_reason`` are the Qt enum member names
    (``"SelectAccount"``, ``"KeyAlreadyRegistered"``, ``"Challenge"``) rather
    than Qt objects, so this function needs no Qt import. Unknown values fall
    back to a readable sentence instead of an empty dialog.
    """
    state = str(state or "")
    relying_party = str(relying_party or "")
    title, body = STATE_TEXT.get(state, ("Passkey", ""))

    if state == "SelectAccount":
        body = ("Which passkey do you want to use for %s?" % relying_party
                if relying_party else "Choose the account to use.")
    elif state == "CollectPin":
        title, body = PIN_REASON_TEXT.get(
            str(pin_reason or ""), PIN_REASON_TEXT["Challenge"])
    elif state == "FinishTokenCollection":
        if relying_party:
            body = "Touch your security key now to finish signing in to %s." % relying_party
    elif state == "RequestFailed":
        body = FAILURE_TEXT.get(
            str(reason or ""),
            "The security key could not complete the request.")
    return {"state": state, "title": title, "body": body}


def pin_error_text(error, attempts=None):
    """A PIN retry's error line, or '' when this is the first attempt."""
    text = PIN_ERROR_TEXT.get(str(error or ""), "")
    if not text:
        return ""
    if isinstance(attempts, int) and attempts > 0:
        text += " %d attempt%s remaining." % (
            attempts, "" if attempts == 1 else "s")
    return text


def _enum_name(value):
    """A Qt enum member's name, or ''. PySide6 spells the member in ``.name``."""
    name = getattr(value, "name", None)
    if name:
        return name
    text = str(value or "")
    return text.rsplit(".", 1)[-1]


def _cancel(request):
    """Cancel once; a request Qt already ended is left alone."""
    try:
        request.cancel()
    except Exception:
        pass


def install_webauthn(page, window):
    """Render Qt's WebAuthn prompts for ``page``, parented to ``window``.

    Returns True when the Qt 6.8+ signal was connected, False on a binding
    without it (or one whose connect fails). Importing PySide6 here, and not at
    module scope, keeps this module importable on a machine with no Qt stack.
    """
    signal = getattr(page, "webAuthUxRequested", None)
    if signal is None:
        return False

    def present(request):
        try:
            _present(request, window)
        except Exception:
            # A broken dialog must not leave the page's promise hanging.
            _cancel(request)

    try:
        signal.connect(present)
    except Exception:
        return False
    return True


def _present(request, window):
    """Show one modal dialog for one request, until it ends or is cancelled."""
    from PySide6.QtCore import QTimer
    from PySide6.QtWidgets import (
        QDialog,
        QDialogButtonBox,
        QLabel,
        QLineEdit,
        QListWidget,
        QVBoxLayout,
    )

    class WebAuthDialog(QDialog):
        """One request's dialog, re-rendered as Qt's state changes.

        ``_settled`` means Qt reported Completed or Cancelled, so the request
        is no longer ours to cancel. ``_cancelled`` guards the user's own
        close so ``cancel()`` lands exactly once.
        """

        def __init__(self):
            super().__init__(window)
            self._settled = False
            self._cancelled = False
            self._auto_selected = False

            self.setWindowTitle("Passkey")
            self.setModal(True)
            self.setMinimumWidth(360)

            self._title = QLabel(self)
            font = self._title.font()
            font.setBold(True)
            self._title.setFont(font)
            self._body = QLabel(self)
            self._body.setWordWrap(True)
            self._accounts = QListWidget(self)
            self._accounts.setVisible(False)
            self._pin = QLineEdit(self)
            self._pin.setEchoMode(QLineEdit.EchoMode.Password)
            self._pin.setVisible(False)
            self._error = QLabel(self)
            self._error.setWordWrap(True)
            self._error.setStyleSheet("color: #ff453a;")

            self._buttons = QDialogButtonBox(self)
            self._accept_button = self._buttons.addButton(
                "Continue", QDialogButtonBox.ButtonRole.AcceptRole)
            self._cancel_button = self._buttons.addButton(
                "Cancel", QDialogButtonBox.ButtonRole.RejectRole)

            layout = QVBoxLayout(self)
            for widget in (self._title, self._body, self._accounts,
                           self._pin, self._error, self._buttons):
                layout.addWidget(widget)

            self._accept_button.clicked.connect(self._submit)
            self._cancel_button.clicked.connect(self.reject)
            self._accounts.itemDoubleClicked.connect(lambda _item: self._submit())
            self._pin.returnPressed.connect(self._submit)
            try:
                request.stateChanged.connect(self._on_state)
            except Exception:
                pass
            self._render()

        # Qt can deliver a state after the person closed the sheet; touching a
        # deleted widget would raise, so settle is checked first.
        def _on_state(self, _state=None):
            if not self._settled:
                self._render()

        def _render(self):
            state = _enum_name(request.state())
            if state in ("Completed", "Cancelled"):
                self._settled = True
                if self.isVisible():
                    self.done(QDialog.DialogCode.Accepted)
                return

            relying_party = ""
            try:
                relying_party = request.relyingPartyId() or ""
            except Exception:
                pass

            pin_reason = ""
            pin_error = ""
            attempts = 0
            if state == "CollectPin":
                try:
                    pin_info = request.pinRequest()
                    pin_reason = _enum_name(pin_info.reason)
                    pin_error = _enum_name(pin_info.error)
                    # A property on this binding; an older one may expose it
                    # as an accessor, so accept either spelling.
                    remaining = getattr(pin_info, "remainingAttempts", 0)
                    attempts = int(remaining() if callable(remaining) else remaining)
                except Exception:
                    pass

            text = request_text(
                state,
                reason=_enum_name(request.requestFailureReason())
                if state == "RequestFailed" else "",
                pin_reason=pin_reason,
                relying_party=relying_party)
            self._title.setText(text["title"])
            self._body.setText(text["body"])

            self._accounts.setVisible(state == "SelectAccount")
            self._pin.setVisible(state == "CollectPin")
            self._error.setText(
                pin_error_text(pin_error, attempts) if state == "CollectPin" else "")
            self._accept_button.setVisible(
                state in ("SelectAccount", "CollectPin"))
            self._cancel_button.setText(
                "Close" if state == "RequestFailed" else "Cancel")

            if state == "SelectAccount":
                self._fill_accounts()
            elif state == "CollectPin":
                # A retry re-enters CollectPin with the authenticator's error:
                # the previous PIN is gone, so start from an empty field.
                self._pin.clear()
                self._pin.setFocus()

        def _fill_accounts(self):
            try:
                names = [str(name) for name in request.userNames()]
            except Exception:
                names = []
            self._accounts.clear()
            for name in names:
                self._accounts.addItem(name)
            # A key with one resident credential leaves nothing to choose.
            # Let the signal's stack unwind first, so Qt's next stateChanged
            # finds a dialog that has finished rendering this one.
            if len(names) == 1 and not self._auto_selected:
                self._auto_selected = True
                name = names[0]
                QTimer.singleShot(
                    0, lambda: (not self._settled)
                    and request.setSelectedAccount(name))

        def _submit(self):
            state = _enum_name(request.state())
            if state == "SelectAccount":
                item = self._accounts.currentItem()
                if item is not None:
                    request.setSelectedAccount(item.text())
            elif state == "CollectPin":
                pin = self._pin.text()
                if pin:
                    request.setPin(pin)

        def reject(self):
            # Dialog rejection is a real cancel: Escape, the window manager's
            # close button and the Cancel/Close button all arrive here.
            if not self._settled and not self._cancelled:
                self._cancelled = True
                _cancel(request)
            super().reject()

        def closeEvent(self, event):
            if not self._settled and not self._cancelled:
                self._cancelled = True
                _cancel(request)
            # Let QDialog finish its event loop (its own closeEvent rejects);
            # reject() sees _cancelled and does not cancel a second time.
            super().closeEvent(event)

    dialog = WebAuthDialog()
    try:
        if not dialog._settled:
            dialog.exec()
    finally:
        try:
            request.stateChanged.disconnect(dialog._on_state)
        except Exception:
            pass
        dialog.deleteLater()
