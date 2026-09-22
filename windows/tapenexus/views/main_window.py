"""Main window: paste bar, segmented filter, and the scrollable queue list."""
from __future__ import annotations

from typing import Dict, List

from PySide6.QtCore import Qt, QUrl
from PySide6.QtGui import QIcon, QDragEnterEvent, QDropEvent
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QHBoxLayout, QVBoxLayout, QLabel, QLineEdit,
    QPushButton, QButtonGroup, QScrollArea, QSizePolicy, QSystemTrayIcon,
    QMenu, QMessageBox,
)

from ..models import extract_urls, looks_supported
from . import theme
from .queue_row import QueueRow
from .settings_dialog import SettingsDialog


FILTERS = [("all", "All"), ("active", "Active"), ("done", "Done"), ("failed", "Failed")]


class MainWindow(QMainWindow):
    def __init__(self, state) -> None:
        super().__init__()
        self.state = state
        self.setWindowTitle("Tape Nexus")
        self.resize(1040, 680)
        self.setMinimumSize(880, 580)
        self.setStyleSheet(f"QMainWindow {{ background: {theme.BG}; }}"
                           f"QMenuBar {{ background: {theme.BG}; color: {theme.TEXT}; }}"
                           f"QMenuBar::item:selected {{ background: {theme.PANEL}; }}")

        self.rows: Dict[str, QWidget] = {}
        self._build_ui()
        self._build_tray()
        self._build_menu()

        # wire state signals
        state.list_changed.connect(self._rebuild_list)
        state.item_changed.connect(self._on_item_changed)
        state.skipped_changed.connect(self._on_skipped)
        state.settings_changed.connect(self._on_settings_changed)
        self._rebuild_list()

        self.setAcceptDrops(True)

    # ── UI ──────────────────────────────────────────────────────────────────
    def _build_ui(self) -> None:
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(16, 12, 16, 12)
        root.setSpacing(10)

        # header: brand + paste bar + settings
        header = QHBoxLayout()
        header.setSpacing(12)
        brand = QLabel("Tape Nexus")
        brand.setStyleSheet(f"font-weight: 600; font-size: 14px; color: {theme.TEXT};")
        header.addWidget(brand)
        header.addStretch(1)

        self.paste = QLineEdit()
        self.paste.setPlaceholderText("Paste a URL or a block of URLs…")
        self.paste.setFixedWidth(300)
        self.paste.returnPressed.connect(self._add_manual)
        header.addWidget(self.paste)

        add_btn = QPushButton("Add")
        add_btn.setStyleSheet(f"background: {theme.ACCENT}; color: #0e1014; padding: 5px 12px; border-radius: 6px; font-weight: 600;")
        add_btn.clicked.connect(self._add_manual)
        header.addWidget(add_btn)

        gear = QPushButton("⚙")
        gear.setToolTip("Settings…")
        gear.setFixedWidth(34)
        gear.clicked.connect(self._open_settings)
        header.addWidget(gear)
        root.addLayout(header)

        # filter bar: segmented All/Active/Done/Failed + bulk actions
        fb = QHBoxLayout()
        fb.setSpacing(8)
        self.filter_group = QButtonGroup(self)
        self.filter_group.setExclusive(True)
        self.filter_buttons = {}
        for key, label in FILTERS:
            b = QPushButton(f"{label} · 0")
            b.setCheckable(True)
            b.clicked.connect(lambda _=False, k=key: self._set_filter(k))
            self.filter_group.addButton(b)
            self.filter_buttons[key] = b
            fb.addWidget(b)
        self.filter_buttons["all"].setChecked(True)
        fb.addStretch(1)
        self.start_all_btn = QPushButton("Start all")
        self.start_all_btn.clicked.connect(lambda: self.state.start_all())
        fb.addWidget(self.start_all_btn)
        self.retry_all_btn = QPushButton("Retry all")
        self.retry_all_btn.clicked.connect(lambda: self.state.retry_all())
        fb.addWidget(self.retry_all_btn)
        self.clear_btn = QPushButton("Clear done")
        self.clear_btn.clicked.connect(lambda: self.state.clear_finished())
        fb.addWidget(self.clear_btn)
        self.pause_btn = QPushButton("Pause all")
        self.pause_btn.clicked.connect(lambda: self.state.pause_all())
        fb.addWidget(self.pause_btn)
        root.addLayout(fb)

        # list
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setStyleSheet(f"QScrollArea {{ border: none; background: {theme.BG}; }}")
        self.list_host = QWidget()
        self.list_layout = QVBoxLayout(self.list_host)
        self.list_layout.setContentsMargins(0, 0, 0, 0)
        self.list_layout.setSpacing(8)
        self.list_layout.addStretch(1)
        self.scroll.setWidget(self.list_host)
        root.addWidget(self.scroll, 1)

        # empty state
        self.empty = QLabel("Nothing here yet.\nCopy a video URL anywhere — supported links are added automatically.\nOr paste one above.")
        self.empty.setAlignment(Qt.AlignCenter)
        self.empty.setStyleSheet(f"color: {theme.MUTED}; font-size: 13px;")
        self.empty.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        root.addWidget(self.empty)

        self.setCentralWidget(central)
        self._refresh_filter_counts()
        self._style_filter_buttons()

    def _style_filter_buttons(self) -> None:
        for b in self.filter_buttons.values():
            b.setStyleSheet(
                f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
                f" color: {theme.TEXT}; padding: 4px 12px; border-radius: 6px; }}"
                f"QPushButton:checked {{ background: {theme.ACCENT}; color: #0e1014; }}"
            )

    def _build_menu(self) -> None:
        m = self.menuBar()
        file_menu = m.addMenu("File")
        file_menu.addAction("Settings…", self._open_settings, "Ctrl+,")
        file_menu.addAction("Quit", self.close, "Ctrl+Q")

    def _build_tray(self) -> None:
        self.tray = QSystemTrayIcon(self)
        # use a simple emoji glyph as the icon fallback if no icon file exists
        from PySide6.QtGui import QPixmap, QPainter, QColor, QFont
        pix = QPixmap(32, 32)
        pix.fill(QColor(theme.ACCENT))
        p = QPainter(pix)
        p.setPen(QColor("#0e1014"))
        f = QFont(); f.setPointSize(16); f.setBold(True); p.setFont(f)
        p.drawText(pix.rect(), Qt.AlignCenter, "⬇")
        p.end()
        self.tray.setIcon(QIcon(pix))
        self.tray.setToolTip("Tape Nexus")
        menu = QMenu()
        menu.addAction("Show", self.showNormal)
        menu.addAction("Pause all", lambda: self.state.pause_all())
        menu.addAction("Resume all", lambda: self.state.resume_all())
        menu.addSeparator()
        menu.addAction("Quit", self.close)
        self.tray.setContextMenu(menu)
        self.tray.show()
        self.state.set_tray(self.tray)

    # ── interactions ────────────────────────────────────────────────────────
    def _add_manual(self) -> None:
        text = self.paste.text()
        self.paste.clear()
        if text.strip():
            self.state.add_manual_urls(text)

    def _open_settings(self) -> None:
        SettingsDialog(self.state, self).exec()

    def _set_filter(self, key: str) -> None:
        self.state.filter = key
        self._rebuild_list()

    def _on_skipped(self, n: int) -> None:
        if n > 0:
            self.statusBar().showMessage(f"{n} copied link(s) skipped — not supported by yt-dlp.", 5000)

    def _on_settings_changed(self) -> None:
        self._rebuild_list()

    # ── list rendering ──────────────────────────────────────────────────────
    def _rebuild_list(self) -> None:
        items = self.state.filtered_items()
        live_ids = {it.id for it in items}
        for gid in list(self.rows.keys()):
            if gid not in live_ids:
                w = self.rows.pop(gid)
                self.list_layout.removeWidget(w)
                w.deleteLater()
        # remove all current widgets from layout, then re-add in order
        for i in reversed(range(self.list_layout.count() - 1)):  # keep the stretch
            w = self.list_layout.itemAt(i).widget()
            if w:
                self.list_layout.removeWidget(w)
        self.rows.clear()
        for it in items:
            row = QueueRow(self.state, it)
            self.rows[it.id] = row
            self.list_layout.insertWidget(self.list_layout.count() - 1, row)
        self.empty.setVisible(not items)
        self._refresh_filter_counts()

    def _on_item_changed(self, item_id: str) -> None:
        # status transitions may move the item between filters
        it = self.state.item(item_id)
        if it is None:
            return
        if item_id in self.rows:
            self.rows[item_id].refresh(it)
        else:
            # it became visible under the current filter → rebuild
            self._rebuild_list()
        self._refresh_filter_counts()

    def _refresh_filter_counts(self) -> None:
        for key, _label in FILTERS:
            self.filter_buttons[key].setText(f"{_label} · {self.state.count_for(key)}")

    # ── drag & drop ─────────────────────────────────────────────────────────
    def dragEnterEvent(self, e: QDragEnterEvent) -> None:
        if e.mimeData().hasUrls() or e.mimeData().hasText():
            e.acceptProposedAction()
        else:
            e.ignore()

    def dropEvent(self, e: QDropEvent) -> None:
        collected: List[str] = []
        if e.mimeData().hasUrls():
            for u in e.mimeData().urls():
                lp = u.toLocalFile()
                if lp.lower().endswith(".txt"):
                    try:
                        with open(lp, "r", encoding="utf-8", errors="replace") as f:
                            collected += extract_urls(f.read())
                    except Exception:
                        pass
                else:
                    collected += extract_urls(u.toString())
        if e.mimeData().hasText():
            collected += extract_urls(e.mimeData().text())
        if collected:
            self.state.add_urls(collected)
            e.acceptProposedAction()
        else:
            e.ignore()

    def closeEvent(self, e) -> None:
        self.tray.hide()
        super().closeEvent(e)