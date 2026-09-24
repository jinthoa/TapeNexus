"""Top-right account control + sign-in dialog.

Replaces the old Account/Achievements settings sections. When signed out the
header shows a "Sign in" button; when signed in it shows an avatar whose popup
holds the email, the achievements badge grid, and Sign out. Achievements are
now surfaced only here (i.e. only for signed-in users).
"""
from __future__ import annotations

from PySide6.QtCore import Qt, QPoint, QPointF
from PySide6.QtGui import QPainter, QColor, QPen, QRectF
from PySide6.QtWidgets import (
    QWidget, QPushButton, QLabel, QLineEdit, QVBoxLayout, QHBoxLayout,
    QGridLayout, QDialog, QMenu, QWidgetAction, QFrame,
    QProgressBar,
)

from ..achievements import Achievement
from . import theme

_AVATAR_GRAD = f"qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 {theme.ACCENT}, stop:1 #b08cff)"


class GoogleGIcon(QWidget):
    """The 4-color Google "G" painted with QPainter (no image asset)."""

    def __init__(self, size: int = 16) -> None:
        super().__init__()
        self.setFixedSize(size, size)

    def paintEvent(self, _) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        w, h = self.width(), self.height()
        cx, cy = w / 2, h / 2
        R = min(w, h) / 2 * 0.94
        midR = R * 0.70
        lw = R * 0.30
        rect = QRectF(cx - midR, cy - midR, 2 * midR, 2 * midR)

        def arc(a0: float, span: float, color: str) -> None:
            pen = QPen(QColor(color), lw)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            p.setPen(pen)
            # drawArc: 1/16th degree; 0 = 3 o'clock; positive span = ccw.
            p.drawArc(rect, int(a0 * 16), int(span * 16))

        arc(30, 90, "#4285F4")        # blue top
        arc(30, -20, "#EA4335")       # red upper-right
        arc(350, -110, "#FBBC05")     # yellow lower-right + bottom
        arc(240, -120, "#34A853")     # green left
        # blue crossbar from center to the right edge
        pen = QPen(QColor("#4285F4"), lw)
        pen.setCapStyle(Qt.PenCapStyle.FlatCap)
        p.setPen(pen)
        p.drawLine(QPointF(cx - midR * 0.10, cy), QPointF(cx + R, cy))
        p.end()


def _initial(email: str) -> str:
    return (email[:1] or "?").upper()


def build_badge(a: Achievement, unlocked: bool) -> QFrame:
    """One cell in the achievements grid: icon + title + subtitle + lock/check."""
    f = QFrame()
    f.setObjectName("badge")
    f.setStyleSheet(
        f"QFrame#badge {{ background: {theme.PANEL}; "
        f"border: 1px solid {theme.LINE}; border-radius: 9px; }}")
    lay = QHBoxLayout(f)
    lay.setContentsMargins(10, 8, 10, 8)
    lay.setSpacing(10)
    sym = QLabel(a.symbol)
    sym.setStyleSheet(
        f"font-size: 17px; color: {theme.ACCENT if unlocked else theme.MUTED};")
    sym.setFixedWidth(22)
    title = QLabel(a.title)
    title.setStyleSheet(
        f"font-size: 12px; font-weight: 600; "
        f"color: {theme.TEXT if unlocked else theme.MUTED};")
    sub = QLabel(a.subtitle)
    sub.setStyleSheet(f"font-size: 10px; color: {theme.MUTED};")
    col = QVBoxLayout()
    col.setSpacing(1)
    col.addWidget(title)
    col.addWidget(sub)
    mark = QLabel("✓" if unlocked else "🔒")
    mark.setStyleSheet(
        f"font-size: 12px; color: {theme.OK if unlocked else theme.MUTED};")
    lay.addWidget(sym)
    lay.addLayout(col, 1)
    lay.addWidget(mark)
    return f


class SignInDialog(QDialog):
    """Sign in / Create account sheet. A segmented control picks the mode
    (clearer than the old checkbox toggle). Email + password + Google."""

    def __init__(self, state, parent=None) -> None:
        super().__init__(parent)
        self.state = state
        self.sync = state.sync
        self.setWindowTitle("Tape Nexus — Sign in")
        self.setFixedWidth(380)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(20, 18, 20, 18)
        outer.setSpacing(14)

        note = QLabel("Sign in to sync your achievements across machines. "
                      "Everything works without an account — sign in to unlock badges.")
        note.setWordWrap(True)
        note.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        outer.addWidget(note)

        self.email = QLineEdit()
        self.email.setPlaceholderText("you@example.com")
        outer.addWidget(self.email)
        self.password = QLineEdit()
        self.password.setPlaceholderText("Password")
        self.password.setEchoMode(QLineEdit.Password)
        self.password.returnPressed.connect(self._submit)
        outer.addWidget(self.password)

        row = QHBoxLayout()
        row.setSpacing(8)
        self.submit_btn = QPushButton("Continue")
        self.submit_btn.setStyleSheet(
            f"background: {theme.ACCENT}; color: #0e1014; padding: 6px 16px;"
            f" border-radius: 6px; font-weight: 600;")
        self.submit_btn.clicked.connect(self._submit)
        self.google_btn = QPushButton()
        self.google_btn.setLayout(QHBoxLayout(self.google_btn))
        self.google_btn.layout().setContentsMargins(8, 0, 10, 0)
        self.google_btn.layout().setSpacing(6)
        self.google_btn.layout().addWidget(GoogleGIcon(16))
        self.google_btn.layout().addWidget(QLabel("Google"))
        self.google_btn.clicked.connect(lambda: self.sync.sign_in_with_google())
        row.addWidget(self.submit_btn)
        row.addWidget(self.google_btn)
        row.addStretch(1)
        self.busy = QProgressBar()
        self.busy.setRange(0, 0)
        self.busy.setFixedWidth(18)
        self.busy.setVisible(False)
        row.addWidget(self.busy)
        outer.addLayout(row)

        self.error = QLabel("")
        self.error.setWordWrap(True)
        self.error.setStyleSheet(f"color: {theme.ERR}; font-size: 11px;")
        outer.addWidget(self.error)

        outer.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        outer.addWidget(cancel, alignment=Qt.AlignRight)

        # React to sync state changes while open.
        self.sync.auth_done.connect(self._on_done)
        self.sync.auth_error.connect(self._on_error)

    # ── actions ───────────────────────────────────────────────────────────────
    def _submit(self) -> None:
        email, password = self.email.text().strip(), self.password.text()
        if not email or not password:
            return
        self.error.setText("")
        self._set_busy(True)
        # One-form auto-detect: sign in, or create the account if it's new.
        self.sync.sign_in_or_sign_up(email, password)

    def _on_done(self, ok: bool) -> None:
        if ok:
            # Merge any server-side progress, then close. pull_and_merge is a
            # no-op if not signed in and marshals the merge onto the GUI thread.
            self.sync.pull_and_merge(self.state.achievements)
            self.password.setText("")
            self._set_busy(False)
            self.accept()
        else:
            self._set_busy(False)

    def _on_error(self, msg: str) -> None:
        self.error.setText(msg)
        self._set_busy(False)

    def _set_busy(self, on: bool) -> None:
        self.busy.setVisible(on)
        self.submit_btn.setEnabled(not on)
        self.google_btn.setEnabled(not on)


class AccountControl(QWidget):
    """Top-right header control: 'Sign in' button (signed out) or avatar
    button (signed in) whose popup shows email + achievements + sign out."""

    def __init__(self, state) -> None:
        super().__init__()
        self.state = state
        self.sync = state.sync
        if not self.sync.is_configured:
            self.setVisible(False)
            return

        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        # Signed-out: a plain "Sign in" button.
        self.signin_btn = QPushButton("Sign in")
        self.signin_btn.setCursor(Qt.PointingHandCursor)
        self.signin_btn.setStyleSheet(
            f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" color: {theme.TEXT}; padding: 5px 12px; border-radius: 6px;"
            f" font-size: 12px; }}"
            f"QPushButton:hover {{ border: 1px solid {theme.ACCENT}; }}")
        self.signin_btn.clicked.connect(self._open_signin)
        lay.addWidget(self.signin_btn)

        # Signed-in: avatar circle with the user's initial.
        self.avatar_btn = QPushButton(_initial(self.sync.email))
        self.avatar_btn.setFixedSize(28, 28)
        self.avatar_btn.setCursor(Qt.PointingHandCursor)
        self.avatar_btn.setStyleSheet(
            f"QPushButton {{ background: {_AVATAR_GRAD}; color: white;"
            f" border: none; border-radius: 14px; font-weight: 700; font-size: 12px; }}"
            f"QPushButton:hover {{ border: 1px solid {theme.TEXT}; }}")
        self.avatar_btn.clicked.connect(self._show_profile)
        lay.addWidget(self.avatar_btn)

        self.sync.signed_in_changed.connect(self._on_signed_in_changed)
        self.sync.email_changed.connect(self._on_email_changed)
        self._apply_state(self.sync.is_signed_in)

    # ── state ──────────────────────────────────────────────────────────────────
    def _apply_state(self, signed_in: bool) -> None:
        self.signin_btn.setVisible(not signed_in)
        self.avatar_btn.setVisible(signed_in)

    def _on_signed_in_changed(self, signed_in: bool) -> None:
        self._apply_state(signed_in)

    def _on_email_changed(self, email: str) -> None:
        self.avatar_btn.setText(_initial(email))

    # ── actions ───────────────────────────────────────────────────────────────
    def _open_signin(self) -> None:
        SignInDialog(self.state, self).exec()

    def _show_profile(self) -> None:
        menu = QMenu(self)
        menu.setStyleSheet(
            f"QMenu {{ background: {theme.BG}; border: 1px solid {theme.LINE};"
            f" padding: 8px; }}")
        wa = QWidgetAction(menu)
        wa.setDefaultWidget(self._build_profile_widget(menu))
        menu.addAction(wa)
        menu.exec(self.avatar_btn.mapToGlobal(QPoint(0, self.avatar_btn.height() + 6)))

    def _build_profile_widget(self, menu: QMenu) -> QWidget:
        w = QWidget()
        w.setFixedWidth(320)
        v = QVBoxLayout(w)
        v.setContentsMargins(12, 10, 12, 10)
        v.setSpacing(10)

        head = QHBoxLayout()
        head.setSpacing(10)
        av = QLabel(_initial(self.sync.email))
        av.setFixedSize(32, 32)
        av.setAlignment(Qt.AlignCenter)
        av.setStyleSheet(
            f"background: {_AVATAR_GRAD}; color: white; border-radius: 16px;"
            f" font-weight: 700; font-size: 13px; border: none;")
        head.addWidget(av)
        col = QVBoxLayout()
        col.setSpacing(2)
        name = QLabel(self.sync.email)
        name.setStyleSheet(f"color: {theme.TEXT}; font-size: 12px; font-weight: 600;")
        tally = QLabel(f"{self.state.achievements.stats.total_completed} downloads · "
                       f"{self.state.achievements.formatted_total_bytes} total")
        tally.setStyleSheet(f"color: {theme.MUTED}; font-size: 10px;")
        col.addWidget(name)
        col.addWidget(tally)
        head.addLayout(col, 1)
        out_btn = QPushButton("Sign out")
        out_btn.setStyleSheet(
            f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" color: {theme.TEXT}; padding: 4px 10px; border-radius: 6px; }}")
        def _signout():
            menu.close()
            self.sync.sign_out()
        out_btn.clicked.connect(_signout)
        head.addWidget(out_btn)
        v.addLayout(head)

        sep = QFrame()
        sep.setFrameShape(QFrame.HLine)
        sep.setStyleSheet(f"color: {theme.LINE};")
        v.addWidget(sep)

        # Identity linking — show whichever provider isn't connected yet.
        provs = list(self.sync.providers)
        has_google = "google" in provs
        has_email = "email" in provs
        if not has_google or not has_email:
            lbl = QLabel("LINKED ACCOUNTS")
            lbl.setStyleSheet(
                f"color: {theme.MUTED}; font-size: 9px; font-weight: 700; letter-spacing: 1px;")
            v.addWidget(lbl)
            row = QHBoxLayout()
            row.setSpacing(8)
            if not has_google:
                gbtn = QPushButton("Link Google")
                gbtn.setStyleSheet(
                    f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
                    f" color: {theme.TEXT}; padding: 3px 10px; border-radius: 6px;"
                    f" font-size: 11px; }}"
                    f"QPushButton:hover {{ border: 1px solid {theme.ACCENT}; }}")
                def _link_g(_=None, m=menu):
                    m.close()
                    self.sync.link_google()
                gbtn.clicked.connect(_link_g)
                row.addWidget(gbtn)
            else:
                gdone = QLabel("✓ Google linked")
                gdone.setStyleSheet(f"color: {theme.MUTED}; font-size: 10px;")
                row.addWidget(gdone)
            if not has_email:
                ebtn = QPushButton("Link email")
                ebtn.setStyleSheet(
                    f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
                    f" color: {theme.TEXT}; padding: 3px 10px; border-radius: 6px;"
                    f" font-size: 11px; }}"
                    f"QPushButton:hover {{ border: 1px solid {theme.ACCENT}; }}")
                def _link_e(_=None, m=menu):
                    m.close()
                    SetPasswordDialog(self.sync, self).exec()
                ebtn.clicked.connect(_link_e)
                row.addWidget(ebtn)
            else:
                edone = QLabel("✓ Email linked")
                edone.setStyleSheet(f"color: {theme.MUTED}; font-size: 10px;")
                row.addWidget(edone)
            row.addStretch(1)
            v.addLayout(row)

            sep2 = QFrame()
            sep2.setFrameShape(QFrame.HLine)
            sep2.setStyleSheet(f"color: {theme.LINE};")
            v.addWidget(sep2)

        lbl = QLabel("ACHIEVEMENTS")
        lbl.setStyleSheet(
            f"color: {theme.MUTED}; font-size: 9px; font-weight: 700; letter-spacing: 1px;")
        v.addWidget(lbl)

        grid = QGridLayout()
        grid.setHorizontalSpacing(8)
        grid.setVerticalSpacing(8)
        for i, a in enumerate(Achievement):
            grid.addWidget(build_badge(a, self.state.achievements.is_unlocked(a)),
                           i // 2, i % 2)
        v.addLayout(grid)
        return w


class SetPasswordDialog(QDialog):
    """Set a password on a Google-only account so email + password also works
    (both identities → one user_id). Opened from the "Link email" button."""

    def __init__(self, sync, parent=None) -> None:
        super().__init__(parent)
        self.sync = sync
        self.setWindowTitle("Tape Nexus — Link email")
        self.setFixedWidth(360)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(20, 18, 20, 18)
        outer.setSpacing(12)

        note = QLabel("Set a password so you can also sign in with email + "
                      "password. Both stay linked to one account.")
        note.setWordWrap(True)
        note.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        outer.addWidget(note)

        self.pw = QLineEdit()
        self.pw.setPlaceholderText("Password")
        self.pw.setEchoMode(QLineEdit.Password)
        outer.addWidget(self.pw)
        self.pw2 = QLineEdit()
        self.pw2.setPlaceholderText("Repeat password")
        self.pw2.setEchoMode(QLineEdit.Password)
        self.pw2.returnPressed.connect(self._submit)
        outer.addWidget(self.pw2)

        row = QHBoxLayout()
        row.setSpacing(8)
        self.submit_btn = QPushButton("Set password")
        self.submit_btn.setStyleSheet(
            f"background: {theme.ACCENT}; color: #0e1014; padding: 6px 16px;"
            f" border-radius: 6px; font-weight: 600;")
        self.submit_btn.clicked.connect(self._submit)
        self.busy = QProgressBar()
        self.busy.setRange(0, 0)
        self.busy.setFixedWidth(18)
        self.busy.setVisible(False)
        row.addWidget(self.submit_btn)
        row.addWidget(self.busy)
        row.addStretch(1)
        outer.addLayout(row)

        self.error = QLabel("")
        self.error.setWordWrap(True)
        self.error.setStyleSheet(f"color: {theme.ERR}; font-size: 11px;")
        outer.addWidget(self.error)

        outer.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        outer.addWidget(cancel, alignment=Qt.AlignRight)

        self.sync.auth_done.connect(self._on_done)
        self.sync.auth_error.connect(self._on_error)

    def _submit(self) -> None:
        p, p2 = self.pw.text(), self.pw2.text()
        if not p or p != p2:
            self.error.setText("Passwords don't match.")
            return
        self.error.setText("")
        self._set_busy(True)
        self.sync.set_password(p)

    def _on_done(self, ok: bool) -> None:
        if ok:
            self._set_busy(False)
            self.accept()
        else:
            self._set_busy(False)

    def _on_error(self, msg: str) -> None:
        self.error.setText(msg)
        self._set_busy(False)

    def _set_busy(self, on: bool) -> None:
        self.busy.setVisible(on)
        self.submit_btn.setEnabled(not on)