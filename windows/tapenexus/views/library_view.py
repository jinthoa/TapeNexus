"""Library tab: a searchable, sortable list of archived completed downloads."""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from PySide6.QtCore import Qt, QUrl
from PySide6.QtGui import QPixmap, QGuiApplication, QDesktopServices
from PySide6.QtNetwork import QNetworkAccessManager, QNetworkRequest, QNetworkReply
from PySide6.QtWidgets import (
    QWidget, QHBoxLayout, QVBoxLayout, QLabel, QLineEdit, QComboBox,
    QPushButton, QScrollArea, QSizePolicy, QFrame, QMenu,
)

from . import theme
from ..library_manager import LibraryEntry


SORTS = [("newest", "Newest"), ("title", "Title"), ("size", "Size"), ("host", "Host")]


class LibraryView(QWidget):
    def __init__(self, state) -> None:
        super().__init__()
        self.state = state
        self._rows = {}  # entry id -> row widget

        root = QVBoxLayout(self)
        root.setContentsMargins(16, 12, 16, 12)
        root.setSpacing(10)

        # toolbar: search + sort + count
        bar = QHBoxLayout()
        bar.setSpacing(8)
        self.search = QLineEdit()
        self.search.setPlaceholderText("Search library…")
        self.search.setFixedWidth(260)
        self.search.textChanged.connect(self._rebuild)
        bar.addWidget(self.search)
        self.sort = QComboBox()
        for key, label in SORTS:
            self.sort.addItem(label, key)
        self.sort.currentIndexChanged.connect(self._rebuild)
        bar.addWidget(self.sort)
        bar.addStretch(1)
        self.count_lbl = QLabel("0 items")
        self.count_lbl.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        bar.addWidget(self.count_lbl)
        root.addLayout(bar)

        # scrollable row list
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setStyleSheet(f"QScrollArea {{ border: none; background: {theme.BG}; }}")
        self.host = QWidget()
        self.list_layout = QVBoxLayout(self.host)
        self.list_layout.setContentsMargins(0, 0, 0, 0)
        self.list_layout.setSpacing(8)
        self.list_layout.addStretch(1)
        self.scroll.setWidget(self.host)
        root.addWidget(self.scroll, 1)

        # empty state
        self.empty = QLabel("Completed downloads are archived here and survive “Clear done”.")
        self.empty.setAlignment(Qt.AlignCenter)
        self.empty.setStyleSheet(f"color: {theme.MUTED}; font-size: 13px;")
        self.empty.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        root.addWidget(self.empty)

        state.library.library_changed.connect(self._rebuild)
        self._rebuild()

    def _rebuild(self) -> None:
        search = self.search.text()
        sort = self.sort.currentData() or "newest"
        shown = self.state.library.query(search, sort)
        live_ids = {e.id for e in shown}
        for gid in list(self._rows.keys()):
            if gid not in live_ids:
                w = self._rows.pop(gid)
                self.list_layout.removeWidget(w)
                w.deleteLater()
        for i in reversed(range(self.list_layout.count() - 1)):  # keep the stretch
            w = self.list_layout.itemAt(i).widget()
            if w:
                self.list_layout.removeWidget(w)
        self._rows.clear()
        for e in shown:
            row = LibraryRow(self.state, e)
            self._rows[e.id] = row
            self.list_layout.insertWidget(self.list_layout.count() - 1, row)
        n = len(self.state.library.entries)
        self.count_lbl.setText(f"{n} item{'s' if n != 1 else ''}")
        self.empty.setVisible(not shown)


class LibraryRow(QFrame):
    def __init__(self, state, entry: LibraryEntry) -> None:
        super().__init__()
        self.state = state
        self.entry = entry
        self.setObjectName("librow")
        self.setStyleSheet(
            f"QFrame#librow {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" border-radius: 10px; }}"
            f"QLabel {{ color: {theme.TEXT}; }}"
        )
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

        self.nam = QNetworkAccessManager(self)
        self._thumb_reply: Optional[QNetworkReply] = None

        root = QHBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(14)

        # thumbnail
        self.thumb = QLabel()
        self.thumb.setFixedSize(132, 74)
        self.thumb.setAlignment(Qt.AlignCenter)
        self.thumb.setStyleSheet(f"background: #0b0d12; border-radius: 6px; color: {theme.MUTED};")
        self.thumb.setText("·")
        root.addWidget(self.thumb)

        # center column: title + host · size · when (+ format chip)
        center = QVBoxLayout()
        center.setSpacing(6)
        title = QLabel(entry.display_title)
        title.setStyleSheet(f"font-weight: 600; font-size: 13px; color: {theme.TEXT};")
        center.addWidget(title)
        try:
            dt = datetime.fromisoformat(entry.completed_at).strftime("%b %d, %H:%M")
        except Exception:
            dt = entry.completed_at or "—"
        meta = QLabel("  ·  ".join([entry.host, LibraryEntry.size_str(entry.total_bytes), dt]))
        meta.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        center.addWidget(meta)
        if entry.format_desc:
            fmt = QLabel(entry.format_desc)
            fmt.setStyleSheet(f"background: {theme.LINE}; color: {theme.TEXT};"
                              f" padding: 1px 6px; border-radius: 6px; font-size: 10px;")
            center.addWidget(fmt)
        root.addLayout(center, 1)

        # action buttons
        actions = QHBoxLayout()
        actions.setSpacing(5)
        actions.addWidget(self._btn("↻", "Re-download", theme.OK,
                                    lambda: self.state.add_candidate(self.entry.url, start_immediately=True)))
        actions.addWidget(self._btn("📁", "Reveal in Explorer", theme.ACCENT2,
                                    lambda: self.state.library.reveal(self.entry.id)))
        actions.addWidget(self._btn("▶", "Open", theme.TEXT,
                                    lambda: self.state.library.open(self.entry.id)))
        actions.addWidget(self._btn("✕", "Remove from library", theme.MUTED,
                                    lambda: self.state.library.remove(self.entry.id)))
        root.addLayout(actions)

        self.setContextMenuPolicy(Qt.CustomContextMenu)
        self.customContextMenuRequested.connect(self._menu)
        self._load_thumb(entry.thumbnail)

    def _btn(self, text, tip, color, handler) -> QPushButton:
        b = QPushButton(text)
        b.setToolTip(tip)
        b.setFixedWidth(34)
        b.setStyleSheet(
            f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" border-radius: 6px; color: {color}; padding: 2px; }}"
            f"QPushButton:hover {{ background: #1d2230; }}"
        )
        b.clicked.connect(handler)
        return b

    def _menu(self, pos) -> None:
        m = QMenu(self)
        m.addAction("Re-download", lambda: self.state.add_candidate(self.entry.url, start_immediately=True))
        m.addAction("Reveal in Explorer", lambda: self.state.library.reveal(self.entry.id))
        m.addAction("Open", lambda: self.state.library.open(self.entry.id))
        m.addSeparator()
        m.addAction("Copy URL", self._copy_url)
        m.addAction("Open in browser", self._open_in_browser)
        m.addSeparator()
        m.addAction("Move file to Trash", lambda: self.state.library.delete_file(self.entry.id))
        m.addAction("Remove from library", lambda: self.state.library.remove(self.entry.id))
        m.exec(self.mapToGlobal(pos))

    def _copy_url(self) -> None:
        QGuiApplication.clipboard().setText(self.entry.url)

    def _open_in_browser(self) -> None:
        QDesktopServices.openUrl(QUrl(self.entry.url))

    # ── thumbnail ───────────────────────────────────────────────────────────
    def _load_thumb(self, url: str) -> None:
        if not url:
            return
        try:
            req = QNetworkRequest(QUrl(url))
            req.setAttribute(QNetworkRequest.RedirectPolicyAttribute,
                             QNetworkRequest.NoLessSafeRedirectPolicy)
            self._thumb_reply = self.nam.get(req)
            self._thumb_reply.finished.connect(self._on_thumb)
        except Exception:
            pass

    def _on_thumb(self) -> None:
        if not self._thumb_reply:
            return
        data = self._thumb_reply.readAll()
        pix = QPixmap()
        if pix.loadFromData(data):
            self.thumb.setPixmap(pix.scaled(132, 74, Qt.KeepAspectRatioByExpanding,
                                            Qt.SmoothTransformation))
        self._thumb_reply.deleteLater()
        self._thumb_reply = None