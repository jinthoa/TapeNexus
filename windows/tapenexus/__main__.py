"""Tape Nexus (Windows) — entry point.

Run from source:  python -m tapenexus
Frozen by PyInstaller via build.py (see windows/build.py).
"""
from __future__ import annotations

import sys

from PySide6.QtWidgets import QApplication

from .app_state import AppState
from .views.main_window import MainWindow
from .views.theme import apply_dark_theme


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Tape Nexus")
    app.setQuitOnLastWindowClosed(True)
    apply_dark_theme(app)

    state = AppState()
    win = MainWindow(state)
    win.show()

    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())