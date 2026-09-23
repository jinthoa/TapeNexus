"""Startup update-check popup: "Tape Nexus X.Y.Z is available" with Skip and
Download-and-install. Matches the existing QDialog + QDialogButtonBox style.
"""
from __future__ import annotations

from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QLabel, QVBoxLayout,
)

from .. import app_updater
from .. import theme


class UpdateDialog(QDialog):
    """`exec()` returns QDialog.Accepted for 'Download and install',
    QDialog.Rejected for 'Skip' / close."""

    def __init__(self, latest_tag: str, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Tape Nexus update available")
        self.setMinimumWidth(360)
        cur = app_updater.current_version()
        title = QLabel(f"<b>Tape Nexus {latest_tag} is available</b>")
        title.setStyleSheet(f"color: {theme.TEXT}; font-size: 14px;")
        body = QLabel(f"You're running {cur}. Download the new version and install it now?")
        body.setStyleSheet(f"color: {theme.MUTED}; font-size: 12px;")
        body.setWordWrap(True)

        btns = QDialogButtonBox()
        install = btns.addButton("Download and install", QDialogButtonBox.AcceptRole)
        btns.addButton("Skip", QDialogButtonBox.RejectRole)
        install.setStyleSheet(
            f"QPushButton {{ background: {theme.ACCENT}; color: #0e1014; "
            f"padding: 6px 16px; border-radius: 6px; }}"
            f"QPushButton:hover {{ background: {theme.ACCENT2}; }}"
        )
        btns.accepted.connect(self.accept)
        btns.rejected.connect(self.reject)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 18, 20, 16)
        lay.setSpacing(10)
        lay.addWidget(title)
        lay.addWidget(body)
        lay.addStretch(1)
        lay.addWidget(btns)