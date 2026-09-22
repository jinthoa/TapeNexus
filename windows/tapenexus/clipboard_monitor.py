"""Polls the system clipboard for new supported URLs (Qt clipboard)."""
from __future__ import annotations

from typing import Set

from PySide6.QtCore import QObject, QTimer, Signal

from .models import extract_urls, looks_supported


class ClipboardMonitor(QObject):
    candidate = Signal(str)

    def __init__(self) -> None:
        super().__init__()
        self.enabled = True
        self.poll_interval = 1.2
        self._seen: Set[str] = set()
        self._last_text = ""
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._tick)

    def start(self) -> None:
        self._timer.start(int(self.poll_interval * 1000))

    def stop(self) -> None:
        self._timer.stop()

    def set_interval(self, seconds: float) -> None:
        self.poll_interval = seconds
        if self._timer.isActive():
            self.start()

    def _tick(self) -> None:
        if not self.enabled:
            return
        from PySide6.QtGui import QGuiApplication
        cb = QGuiApplication.clipboard()
        text = cb.text() or ""
        if text == self._last_text:
            return
        self._last_text = text
        for u in extract_urls(text):
            cleaned = u.strip().strip(".,;:!?")
            if cleaned in self._seen or not looks_supported(cleaned):
                continue
            self._seen.add(cleaned)
            if len(self._seen) > 200:
                self._seen.pop()
            self.candidate.emit(cleaned)

    def forget(self, url: str) -> None:
        self._seen.discard(url)