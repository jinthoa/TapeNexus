"""Dark palette + shared style helpers for the Windows UI."""
from PySide6.QtGui import QColor, QPalette, QFont
from PySide6.QtWidgets import QApplication


BG = "#0e1014"
PANEL = "#161922"
LINE = "#232734"
TEXT = "#e6e8ee"
MUTED = "#8a90a2"
ACCENT = "#7c9cff"
ACCENT2 = "#4fd1c5"
OK = "#3fb950"
WARN = "#d29922"
ERR = "#f85149"


def apply_dark_theme(app: QApplication) -> None:
    app.setStyle("Fusion")
    pal = QPalette()
    pal.setColor(QPalette.Window, QColor(BG))
    pal.setColor(QPalette.WindowText, QColor(TEXT))
    pal.setColor(QPalette.Base, QColor(PANEL))
    pal.setColor(QPalette.AlternateBase, QColor(PANEL))
    pal.setColor(QPalette.Text, QColor(TEXT))
    pal.setColor(QPalette.Button, QColor(PANEL))
    pal.setColor(QPalette.ButtonText, QColor(TEXT))
    pal.setColor(QPalette.Highlight, QColor(ACCENT))
    pal.setColor(QPalette.HighlightedText, QColor("#0e1014"))
    pal.setColor(QPalette.ToolTipBase, QColor(PANEL))
    pal.setColor(QPalette.ToolTipText, QColor(TEXT))
    app.setPalette(pal)


ROW_QSS = f"""
QWidget#row {{ background: {PANEL}; border: 1px solid {LINE}; border-radius: 10px; }}
QLabel {{ color: {TEXT}; }}
"""


def muted_font(size: int = 11) -> QFont:
    f = QFont()
    f.setPointSize(size)
    return f


def mono_font(size: int = 10) -> QFont:
    f = QFont("Consolas")
    f.setPointSize(size)
    return f