"""Persistent library of completed downloads — survives 'Clear done'.

A separate archive store from the live queue: when a download finishes it's
snapshotted into library.json (capped at MAX_ENTRIES, oldest drop off). The
Library tab browses, searches, re-downloads, reveals, and trashes from it.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass, asdict
from datetime import datetime
from typing import List, Optional

from PySide6.QtCore import QObject, Signal

from .models import DownloadItem

MAX_ENTRIES = 2000


@dataclass
class LibraryEntry:
    id: str
    url: str
    title: str = ""
    uploader: str = ""
    thumbnail: str = ""
    duration_str: str = ""
    format_desc: str = ""
    total_bytes: int = 0
    output_file_path: str = ""
    completed_at: str = ""

    @property
    def display_title(self) -> str:
        return self.title or self.url

    @property
    def host(self) -> str:
        m = re.match(r"https?://([^/]+)", self.url)
        if not m:
            return self.url
        h = m.group(1).lower()
        return h[4:] if h.startswith("www.") else h

    @staticmethod
    def size_str(n: int) -> str:
        if n <= 0:
            return "—"
        x = float(n)
        for unit in ("B", "KB", "MB", "GB"):
            if abs(x) < 1024:
                return f"{x:.1f} {unit}" if unit != "B" else f"{int(x)} B"
            x /= 1024.0
        return f"{x:.1f} TB"

    @staticmethod
    def from_item(it: DownloadItem) -> "LibraryEntry":
        return LibraryEntry(
            id=it.id, url=it.url, title=it.title, uploader=it.uploader,
            thumbnail=it.thumbnail, duration_str=it.duration_str,
            format_desc=it.format_desc, total_bytes=it.total_bytes,
            output_file_path=it.output_file_path,
            completed_at=it.completed_at or datetime.now().isoformat(),
        )

    def to_dict(self) -> dict:
        return asdict(self)

    @staticmethod
    def from_dict(d: dict) -> "LibraryEntry":
        d = {k: v for k, v in d.items() if k in LibraryEntry.__dataclass_fields__}
        return LibraryEntry(**d)


class LibraryManager(QObject):
    library_changed = Signal()

    def __init__(self, appdata_dir: str) -> None:
        super().__init__()
        self._path = os.path.join(appdata_dir, "library.json")
        self.entries: List[LibraryEntry] = []
        self._did_load = False
        self._load()

    def _load(self) -> None:
        try:
            with open(self._path, "r", encoding="utf-8") as f:
                snap = json.load(f)
            self.entries = [LibraryEntry.from_dict(d) for d in snap.get("entries", [])]
            self._did_load = True
        except Exception:
            self.entries = []

    def _save(self) -> None:
        snap = {"version": 1, "entries": [e.to_dict() for e in self.entries]}
        try:
            tmp = self._path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(snap, f, indent=2)
            os.replace(tmp, self._path)
        except Exception:
            pass

    def archive(self, it: DownloadItem) -> None:
        """Snapshot a finished download. Dedupes by URL (a re-download refreshes
        the existing row instead of adding a duplicate), then enforces the cap."""
        entry = LibraryEntry.from_item(it)
        for i, e in enumerate(self.entries):
            if e.url == it.url:
                self.entries[i] = entry
                self._enforce_cap()
                self._save()
                self.library_changed.emit()
                return
        self.entries.insert(0, entry)
        self._enforce_cap()
        self._save()
        self.library_changed.emit()

    def seed(self, items: List[DownloadItem]) -> None:
        """One-time first-run import of currently-done queue items so existing
        users don't lose their history the first time they hit Clear done."""
        if self._did_load or self.entries:
            return
        done = [it for it in items if it.status == "done"]
        if not done:
            return
        self.entries = [LibraryEntry.from_item(it) for it in done]
        # Legacy done items have no completed_at — fall back to added_at.
        for e, it in zip(self.entries, done):
            if not e.completed_at and it.added_at:
                e.completed_at = it.added_at
        self._enforce_cap()
        self._save()
        self.library_changed.emit()

    def remove(self, entry_id: str) -> None:
        """Drop from the library index only — the file stays on disk."""
        self.entries = [e for e in self.entries if e.id != entry_id]
        self._save()
        self.library_changed.emit()

    def delete_file(self, entry_id: str) -> None:
        """Trash the downloaded file AND remove from the library."""
        e = self.get(entry_id)
        if e and e.output_file_path:
            try:
                import send2trash
                send2trash.send2trash(e.output_file_path)
            except Exception:
                try:
                    os.remove(e.output_file_path)
                except Exception:
                    pass
        self.remove(entry_id)

    def reveal(self, entry_id: str) -> None:
        e = self.get(entry_id)
        if not e or not e.output_file_path:
            return
        try:
            subprocess.Popen(["explorer", "/select,", os.path.abspath(e.output_file_path)])
        except Exception:
            try:
                os.startfile(os.path.dirname(e.output_file_path))  # type: ignore[attr-defined]
            except Exception:
                pass

    def open(self, entry_id: str) -> None:
        e = self.get(entry_id)
        if not e or not e.output_file_path:
            return
        try:
            os.startfile(e.output_file_path)  # type: ignore[attr-defined]
        except Exception:
            pass

    def get(self, entry_id: str) -> Optional[LibraryEntry]:
        for e in self.entries:
            if e.id == entry_id:
                return e
        return None

    def query(self, search: str, sort: str) -> List[LibraryEntry]:
        q = search.strip().lower()
        result = list(self.entries)
        if q:
            result = [e for e in result
                      if q in e.title.lower() or q in e.host.lower() or q in e.url.lower()]
        if sort == "title":
            result.sort(key=lambda e: e.display_title.lower())
        elif sort == "size":
            result.sort(key=lambda e: e.total_bytes, reverse=True)
        elif sort == "host":
            result.sort(key=lambda e: e.host.lower())
        else:  # newest
            result.sort(key=lambda e: e.completed_at or "", reverse=True)
        return result

    def _enforce_cap(self) -> None:
        if len(self.entries) <= MAX_ENTRIES:
            return
        self.entries.sort(key=lambda e: e.completed_at or "", reverse=True)
        self.entries = self.entries[:MAX_ENTRIES]