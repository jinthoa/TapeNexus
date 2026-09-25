"""Subscriptions: channel/playlist URLs the app polls on an interval, auto-
queuing any new entries. The first check of a fresh subscription is a baseline
— it records the current entries but queues nothing, so adding a channel
doesn't dump its entire back catalogue; only videos published after that go in.
Persisted to subscriptions.json in the appdata dir."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from typing import List, Optional
from urllib.parse import urlparse

from PySide6.QtCore import QObject, Signal


@dataclass
class Subscription:
    id: str
    url: str
    title: str = ""
    preset: str = "best"
    interval_minutes: int = 360
    enabled: bool = True
    last_checked_at: str = ""
    known_urls: List[str] = field(default_factory=list)
    last_new_count: int = 0

    @property
    def host(self) -> str:
        try:
            h = urlparse(self.url).hostname or self.url
            return h[4:] if h.startswith("www.") else h
        except Exception:
            return self.url

    @property
    def display_title(self) -> str:
        return self.title or self.url

    def to_dict(self) -> dict:
        return {
            "id": self.id, "url": self.url, "title": self.title,
            "preset": self.preset, "interval_minutes": self.interval_minutes,
            "enabled": self.enabled, "last_checked_at": self.last_checked_at,
            "known_urls": self.known_urls, "last_new_count": self.last_new_count,
        }

    @staticmethod
    def from_dict(d: dict) -> "Subscription":
        return Subscription(
            id=d.get("id") or str(__import__("uuid").uuid4()),
            url=d.get("url", ""), title=d.get("title", ""),
            preset=d.get("preset", "best"),
            interval_minutes=int(d.get("interval_minutes", 360)),
            enabled=bool(d.get("enabled", True)),
            last_checked_at=d.get("last_checked_at", ""),
            known_urls=list(d.get("known_urls", []) or []),
            last_new_count=int(d.get("last_new_count", 0)),
        )


MAX_SUBS = 50


class SubscriptionManager(QObject):
    subs_changed = Signal()

    def __init__(self, appdata_dir: str) -> None:
        super().__init__()
        self._path = os.path.join(appdata_dir, "subscriptions.json")
        self.subs: List[Subscription] = []
        self._load()

    def _load(self) -> None:
        try:
            with open(self._path, "r", encoding="utf-8") as f:
                snap = json.load(f)
            self.subs = [Subscription.from_dict(d) for d in snap.get("subs", [])]
        except Exception:
            self.subs = []

    def _save(self) -> None:
        try:
            tmp = self._path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"version": 1, "subs": [s.to_dict() for s in self.subs]},
                          f, indent=2, sort_keys=True)
            os.replace(tmp, self._path)
        except Exception:
            pass

    def add(self, sub: Subscription) -> None:
        if len(self.subs) >= MAX_SUBS:
            return
        for i, s in enumerate(self.subs):
            if s.url == sub.url:
                self.subs[i] = sub
                self._save()
                self.subs_changed.emit()
                return
        self.subs.insert(0, sub)
        self._save()
        self.subs_changed.emit()

    def remove(self, sub_id: str) -> None:
        self.subs = [s for s in self.subs if s.id != sub_id]
        self._save()
        self.subs_changed.emit()

    def update(self, sub_id: str, **fields) -> None:
        for s in self.subs:
            if s.id == sub_id:
                for k, v in fields.items():
                    setattr(s, k, v)
                self._save()
                self.subs_changed.emit()
                return

    def get(self, sub_id: str) -> Optional[Subscription]:
        for s in self.subs:
            if s.id == sub_id:
                return s
        return None