"""Top-right account control + sign-in dialog.

Replaces the old Account/Achievements settings sections. When signed out the
header shows a "Sign in" button; when signed in it shows an avatar whose popup
holds the email, the achievements badge grid, and Sign out. Achievements are
now surfaced only here (i.e. only for signed-in users).
"""
from __future__ import annotations

from PySide6.QtCore import Qt, QPoint, QPointF, QTimer
from PySide6.QtGui import QPainter, QColor, QPen, QRectF
from PySide6.QtWidgets import (
    QWidget, QPushButton, QLabel, QLineEdit, QVBoxLayout, QHBoxLayout,
    QGridLayout, QDialog, QMenu, QWidgetAction, QFrame,
    QProgressBar, QCheckBox, QScrollArea,
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


def build_badge(a: Achievement, unlocked: bool, stats) -> QFrame:
    """One cell in the achievements grid. Uniform fixed-height cell so the grid
    spacing stays even; one consistent title size (no per-title scaling);
    subtitle wraps up to 2 lines so the full description is readable; locked
    grindy badges show a thin progress bar + '47/50'. Secret achievements hide
    their real title/subtitle/symbol behind a '???' card until unlocked, then
    reveal with a purple tint + sparkle."""
    hidden = a.secret and not unlocked
    prog = None if unlocked else a.progress(stats)
    show_bar = prog is not None and prog[1] >= 2
    f = QFrame()
    f.setObjectName("badge")
    f.setFixedHeight(64)
    f.setStyleSheet(
        f"QFrame#badge {{ background: {theme.PANEL}; "
        f"border: 1px solid {theme.LINE}; border-radius: 9px; }}")
    lay = QHBoxLayout(f)
    lay.setContentsMargins(10, 8, 10, 8)
    lay.setSpacing(10)
    if unlocked and a.secret:
        sym_color = "#b46cff"
    elif unlocked:
        sym_color = theme.ACCENT
    else:
        sym_color = theme.MUTED
    sym = QLabel("❓" if hidden else a.symbol)
    sym.setStyleSheet(f"font-size: 18px; color: {sym_color};")
    sym.setFixedWidth(24)
    title_text = "Secret" if hidden else a.title
    if unlocked and a.secret:
        title_text = f"{title_text} ✨"
    title = QLabel(title_text)
    title_color = sym_color if (unlocked and a.secret) else (theme.TEXT if unlocked else theme.MUTED)
    title.setStyleSheet(
        f"font-size: 12px; font-weight: 600; color: {title_color};")
    title.setWordWrap(False)
    sub_text = "Hidden — keep going to reveal." if hidden else a.subtitle
    sub = QLabel(sub_text)
    sub.setStyleSheet(f"font-size: 10px; color: {theme.MUTED};")
    sub.setWordWrap(not show_bar)   # 1 line when a bar is present, else wrap
    col = QVBoxLayout()
    col.setSpacing(2)
    col.setContentsMargins(0, 0, 0, 0)
    col.addWidget(title)
    col.addWidget(sub)
    if show_bar:
        current, target, unit = prog
        frac = max(0.0, min(current / target, 1.0)) if target else 0.0
        bar = QProgressBar()
        bar.setRange(0, 100)
        bar.setValue(int(frac * 100))
        bar.setFixedHeight(6)
        bar.setTextVisible(False)
        bar.setStyleSheet(
            f"QProgressBar {{ background: {theme.BG}; border: none; border-radius: 3px; }}"
            f" QProgressBar::chunk {{ background: {theme.ACCENT}; border-radius: 3px; }}")
        plbl = QLabel(f"{int(current)}/{int(target)}{unit}")
        plbl.setStyleSheet(f"font-size: 9px; color: {theme.MUTED};")
        brow = QHBoxLayout()
        brow.setContentsMargins(0, 0, 0, 0)
        brow.setSpacing(6)
        brow.addWidget(bar, 1)
        brow.addWidget(plbl)
        col.addLayout(brow)
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
        w.setFixedWidth(440)
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
        # Stats strip: composite score · best streak · hosts seen.
        st = self.state.achievements.stats
        strip = QLabel(
            f"🏆 {st.score}   🔥 {st.best_streak}d   🌐 {len(st.hosts_seen)}")
        strip.setStyleSheet(f"color: {theme.MUTED}; font-size: 9px; font-weight: 500;")
        col.addWidget(strip)
        head.addLayout(col, 1)
        lb_btn = QPushButton("🏆 Leaderboard")
        lb_btn.setCursor(Qt.PointingHandCursor)
        lb_btn.setStyleSheet(
            f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" color: {theme.TEXT}; padding: 4px 10px; border-radius: 6px; }}"
            f"QPushButton:hover {{ border: 1px solid {theme.ACCENT}; }}")
        def _open_lb(_=None, m=menu):
            m.close()
            LeaderboardDialog(self.state, self).exec()
        lb_btn.clicked.connect(_open_lb)
        head.addWidget(lb_btn)
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
            grid.addWidget(build_badge(a, self.state.achievements.is_unlocked(a),
                                       self.state.achievements.stats),
                           i // 2, i % 2)
        # 23 badges now — wrap the grid in a scroll area with a bounded height
        # so the popup never grows past the screen and stays scrollable.
        grid_host = QWidget()
        grid_host.setLayout(grid)
        grid_host.setStyleSheet("background: transparent;")
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setMaximumHeight(440)
        scroll.setStyleSheet(
            f"QScrollArea {{ background: transparent; border: none; }}"
            f" QScrollBar:vertical {{ background: {theme.PANEL}; width: 8px; }}"
            f" QScrollBar::handle:vertical {{ background: {theme.LINE};"
            f" border-radius: 4px; min-height: 20px; }}")
        scroll.setWidget(grid_host)
        v.addWidget(scroll)
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


class LeaderboardDialog(QDialog):
    """Global, opt-in leaderboard. Shows the opt-in toggle + display name, the
    user's rank + composite score, and the top-100 board (their row
    highlighted). Opting in exposes only display_name/score/total_completed via
    the `leaderboard` view — full stats stay private."""

    def __init__(self, state, parent=None) -> None:
        super().__init__(parent)
        self.state = state
        self.sync = state.sync
        self.ach = state.achievements
        self.setWindowTitle("Tape Nexus — Leaderboard")
        self.setFixedSize(460, 560)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(18, 14, 18, 14)
        outer.setSpacing(12)

        # Opt-in profile card
        card = QFrame()
        card.setStyleSheet(
            f"QFrame {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" border-radius: 9px; }}")
        cl = QVBoxLayout(card)
        cl.setContentsMargins(10, 10, 10, 10)
        cl.setSpacing(8)
        self.opt_in = QCheckBox("Show me on the board")
        self.opt_in.setStyleSheet(f"color: {theme.TEXT}; font-size: 11px;")
        cl.addWidget(self.opt_in)
        row = QHBoxLayout()
        row.setSpacing(8)
        self.name_edit = QLineEdit()
        self.name_edit.setPlaceholderText("Display name")
        self.name_edit.setStyleSheet(
            f"QLineEdit {{ background: {theme.BG}; color: {theme.TEXT};"
            f" border: 1px solid {theme.LINE}; border-radius: 6px; padding: 4px 8px; }}"
            f"QLineEdit:disabled {{ color: {theme.MUTED}; }}")
        row.addWidget(self.name_edit, 1)
        self.save_btn = QPushButton("Save")
        self.save_btn.setCursor(Qt.PointingHandCursor)
        self.save_btn.setStyleSheet(
            f"QPushButton {{ background: {theme.ACCENT}; color: #0e1014; padding: 5px 14px;"
            f" border-radius: 6px; font-weight: 600; }}"
            f"QPushButton:disabled {{ background: {theme.PANEL}; color: {theme.MUTED}; }}")
        self.save_btn.clicked.connect(self._save)
        row.addWidget(self.save_btn)
        cl.addLayout(row)
        priv = QLabel("Only your display name, score, and download count are public. "
                      "Everything else stays private.")
        priv.setWordWrap(True)
        priv.setStyleSheet(f"color: {theme.MUTED}; font-size: 9px;")
        cl.addWidget(priv)
        outer.addWidget(card)

        # Rank + score + downloads
        stats_row = QHBoxLayout()
        stats_row.setSpacing(18)
        self.rank_lbl = self._stat("—", "Your rank")
        self.score_lbl = self._stat(str(self.ach.stats.score), "Your score")
        self.dl_lbl = self._stat(str(self.ach.stats.total_completed), "Downloads")
        stats_row.addWidget(self.rank_lbl)
        stats_row.addWidget(self.score_lbl)
        stats_row.addWidget(self.dl_lbl)
        stats_row.addStretch(1)
        refresh = QPushButton("⟳")
        refresh.setCursor(Qt.PointingHandCursor)
        refresh.setFixedWidth(26)
        refresh.setStyleSheet(
            f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" border-radius: 6px; color: {theme.MUTED}; font-size: 12px; }}")
        refresh.clicked.connect(lambda: self._load())
        stats_row.addWidget(refresh)
        outer.addLayout(stats_row)

        self.error = QLabel("")
        self.error.setStyleSheet(f"color: {theme.ERR}; font-size: 11px;")
        outer.addWidget(self.error)

        # Top 100 / Near you segmented toggle.
        seg = QHBoxLayout()
        seg.setSpacing(6)
        self.mode = 0  # 0 = Top 100, 1 = Near you
        self.seg_top = QPushButton("Top 100")
        self.seg_near = QPushButton("Near you")
        for b in (self.seg_top, self.seg_near):
            b.setCursor(Qt.PointingHandCursor)
            b.setFixedHeight(26)
        self.seg_top.clicked.connect(lambda: self._set_mode(0))
        self.seg_near.clicked.connect(lambda: self._set_mode(1))
        seg.addWidget(self.seg_top)
        seg.addWidget(self.seg_near)
        seg.addStretch(1)
        outer.addLayout(seg)
        self._style_seg()

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setStyleSheet(
            f"QScrollArea {{ border: 1px solid {theme.LINE}; border-radius: 8px;"
            f" background: {theme.BG}; }}")
        self.list_host = QWidget()
        self.list_host.setStyleSheet("background: transparent;")
        self.list_layout = QVBoxLayout(self.list_host)
        self.list_layout.setContentsMargins(6, 6, 6, 6)
        self.list_layout.setSpacing(4)
        self.list_layout.addStretch(1)
        self.scroll.setWidget(self.list_host)
        outer.addWidget(self.scroll, 1)

        done = QPushButton("Done")
        done.setCursor(Qt.PointingHandCursor)
        done.setStyleSheet(
            f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" color: {theme.TEXT}; padding: 6px 18px; border-radius: 6px; }}")
        done.clicked.connect(self.accept)
        outer.addWidget(done, alignment=Qt.AlignRight)

        # Seed local profile into the controls, then load the board.
        self.opt_in.setChecked(bool(self.ach.stats.leaderboard_opt_in))
        self.name_edit.setText(self.ach.stats.display_name)
        self.opt_in.toggled.connect(self.name_edit.setEnabled)
        self.name_edit.setEnabled(self.opt_in.isChecked())
        self._entries, self._rank = [], None
        self._near_above, self._near_below = [], []
        QTimer.singleShot(0, self._load)

    def _stat(self, value: str, label: str) -> QLabel:
        w = QLabel(f"<b style='font-size:15px;color:{theme.TEXT}'>{value}</b>"
                   f"<br><span style='color:{theme.MUTED};font-size:9px'>{label}</span>")
        w.setTextFormat(Qt.RichText)
        return w

    def _clear_list(self) -> None:
        while self.list_layout.count() > 1:
            it = self.list_layout.takeAt(0)
            w = it.widget()
            if w is not None:
                w.deleteLater()

    def _style_seg(self) -> None:
        """Highlight the active mode button."""
        on_css = (f"QPushButton {{ background: {theme.ACCENT}; color: #0e1014;"
                  f" border: none; border-radius: 6px; font-weight: 600; }}")
        off_css = (f"QPushButton {{ background: {theme.PANEL}; color: {theme.MUTED};"
                   f" border: 1px solid {theme.LINE}; border-radius: 6px; }}"
                   f"QPushButton:hover {{ border: 1px solid {theme.ACCENT}; }}")
        self.seg_top.setStyleSheet(on_css if self.mode == 0 else off_css)
        self.seg_near.setStyleSheet(on_css if self.mode == 1 else off_css)

    def _set_mode(self, m: int) -> None:
        if m == self.mode:
            return
        self.mode = m
        self._style_seg()
        self._render()

    def _load(self) -> None:
        self.error.setText("")
        self._clear_list()
        loading = QLabel("Loading…")
        loading.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        loading.setAlignment(Qt.AlignCenter)
        self.list_layout.insertWidget(0, loading)
        score = int(self.ach.stats.score)

        def work() -> None:
            entries = self.sync.fetch_leaderboard()
            rank = self.sync.fetch_my_rank(score)
            above, below = self.sync.fetch_near_me(score)
            QTimer.singleShot(0, lambda: self._loaded(entries, rank, above, below))

        import threading
        threading.Thread(target=work, daemon=True).start()

    def _loaded(self, entries: list, rank, above: list, below: list) -> None:
        self._entries, self._rank = entries, rank
        self._near_above, self._near_below = above, below
        self.rank_lbl.setText(
            f"<b style='font-size:15px;color:{theme.TEXT}'>#{rank if rank else '—'}</b>"
            f"<br><span style='color:{theme.MUTED};font-size:9px'>Your rank</span>")
        self._render()

    def _render(self) -> None:
        self._clear_list()
        my_id = self.sync._uid()
        if self.mode == 0:
            self._render_top(my_id)
        else:
            self._render_near(my_id)

    def _render_top(self, my_id: str) -> None:
        if not self._entries:
            empty = QLabel("No one's on the board yet — be the first.")
            empty.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
            empty.setAlignment(Qt.AlignCenter)
            self.list_layout.insertWidget(0, empty)
            return
        for i, e in enumerate(self._entries):
            is_me = e.get("user_id") == my_id
            self.list_layout.insertWidget(i, self._row(i + 1, e, is_me))

    def _render_near(self, my_id: str) -> None:
        r = self._rank or 0
        above = list(reversed(self._near_above))   # closest-to-me last (top of list)
        above_start = r - len(above)               # first above row's rank
        if not above and not self._near_below:
            empty = QLabel("No one's on the board yet — be the first.")
            empty.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
            empty.setAlignment(Qt.AlignCenter)
            self.list_layout.insertWidget(0, empty)
            return
        i = 0
        for j, e in enumerate(above):
            self.list_layout.insertWidget(i, self._row(above_start + j, e, False))
            i += 1
        for j, e in enumerate(self._near_below):
            is_me = e.get("user_id") == my_id
            self.list_layout.insertWidget(i, self._row(r + j, e, is_me))
            i += 1

    def _row(self, rank: int, e: dict, is_me: bool) -> QFrame:
        f = QFrame()
        bg = theme.ACCENT + "20" if is_me else "transparent"
        border = theme.ACCENT + "66" if is_me else "transparent"
        f.setStyleSheet(
            f"QFrame {{ background: {bg}; border: 1px solid {border}; border-radius: 6px; }}")
        lay = QHBoxLayout(f)
        lay.setContentsMargins(10, 6, 10, 6)
        lay.setSpacing(10)
        rkl = QLabel(str(rank) if rank and rank > 0 else "—")
        rkl.setFixedWidth(28)
        rkl.setStyleSheet(
            f"font-size: 11px; font-weight: 600; color: "
            f"{theme.ACCENT if 0 < rank <= 3 else theme.MUTED};")
        lay.addWidget(rkl)
        nm = QLabel(e.get("display_name", ""))
        nm.setStyleSheet(
            f"font-size: 12px; font-weight: {'700' if is_me else '500'}; color: "
            f"{theme.ACCENT if is_me else theme.TEXT};")
        lay.addWidget(nm, 1)
        sc = QLabel(str(e.get("score", 0)))
        sc.setFixedWidth(70)
        sc.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        sc.setStyleSheet(f"font-size: 11px; font-weight: 600; color: {theme.TEXT};")
        lay.addWidget(sc)
        dl = QLabel(f"{e.get('total_completed', 0)} dl")
        dl.setFixedWidth(50)
        dl.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        dl.setStyleSheet(f"font-size: 10px; color: {theme.MUTED};")
        lay.addWidget(dl)
        return f

    def _save(self) -> None:
        name = self.name_edit.text().strip()
        opt = self.opt_in.isChecked()
        if not opt or not name:
            return
        self.save_btn.setEnabled(False)
        self.ach.set_leaderboard_profile(name, opt)
        self.sync.push_achievements(self.ach.stats)
        # Push is fire-and-forget on a thread; reload the board shortly after.
        QTimer.singleShot(600, self._load)
        self.save_btn.setEnabled(True)